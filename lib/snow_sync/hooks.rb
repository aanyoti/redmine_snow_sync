module SnowSync
  class Hooks < Redmine::Hook::ViewListener
    CONTRACTOR_ROLE_ID = 20

    PROVISIONING_CF_NAMES = {
      a_pop:     'A-End Termination POP',
      a_device:  'A-End Switch/Router',
      a_port:    'A-End Termination Port',
      b_pop:     'B-End Termination POP',
      b_device:  'B-End Switch/Router',
      b_port:    'B-End Termination Port',
      vlan_ip:   'VLAN/IP',
      bandwidth: 'Bandwidth Capacity',
    }.freeze

    # A-B end termination CFs — visible from Splicing (57) and Service Delivery (59) onwards.
    AB_CF_IDS        = [98, 99, 100, 101, 102, 103, 104, 105].freeze
    AB_SHOW_STATUSES = [57, 59, 53, 60, 61, 62, 17].freeze

    # Optical measurement CFs — only visible from Splicing (57) onwards.
    OPTICAL_CF_IDS        = [106, 107, 108].freeze
    OPTICAL_SHOW_STATUSES = [57, 52, 59, 53, 60, 61, 62, 17].freeze

    # Project Code CF — visible from Service Scheduling (48) onwards; hidden at Service Request Review.
    PROJECT_CODE_CF_IDS        = [109].freeze
    PROJECT_CODE_HIDE_STATUSES = [47, 1, 7].freeze  # Service Request Review and earlier intake statuses

    # Jump Reason CF — shown only when PM selects a status that skips steps in the sequence.
    JUMP_REASON_CF_ID   = 121
    TRACKER_14_SEQUENCE = [47, 48, 49, 24, 50, 90, 51, 57, 52, 59, 53, 60, 61, 62, 17].freeze

    PROJECTS_DEPT_ROLE_ID = 7

    # Hides the existing attachments list for contractor-only users.
    # The upload widget (#attachments_fields) uses a different selector and stays visible.
    # Also hides the Kanban plugin's Block reason widget from all issues (PMs were
    # entering notes there by mistake instead of the Notes field).
    # For contractor-only users on an issue page, injects a PM banner below the issue title.
    def view_layouts_base_html_head(context = {})
      css = +'<style>#issue-blocked-reason { display: none !important; }</style>'
      return css.html_safe unless contractor_only_user?

      css << '<style>.attachments { display: none !important; }</style>'

      # Only inject PM banner on issue show pages
      controller = context[:controller]
      if controller.is_a?(IssuesController) && controller.action_name == 'show'
        issue = controller.instance_variable_get(:@issue)
        if issue&.project
          pm = project_manager_for(issue.project)
          if pm
            css << %(<style>
              #pm-banner{display:flex;align-items:center;gap:10px;
                background:#1a3a6b;color:#fff;
                padding:8px 16px;border-radius:6px;
                margin:8px 0 12px;font-size:13px;font-weight:600;}
              #pm-banner span{opacity:.8;font-weight:400;}
            </style>
            <script>
              document.addEventListener('DOMContentLoaded',function(){
                var h2=document.querySelector('h2.inline-block');
                if(h2){
                  var b=document.createElement('div');
                  b.id='pm-banner';
                  b.innerHTML='<span>&#128100; Project Manager:</span>&nbsp;#{ERB::Util.html_escape(pm.name)}';
                  h2.parentNode.insertBefore(b,h2.nextSibling);
                }
              });
            </script>)
          end
        end
      end

      css.html_safe
    end

    # Issues index page (Organic project only): inject CTO export button.
    def view_issues_index_bottom(context = {})
      project = context[:project]
      return '' unless project&.id == 5

      allowed = User.current.admin? ||
                User.current.roles.any? { |r| r.name == 'Commercial Lead' } ||
                User.current.groups.any? { |g| [8, 9].include?(g.id) }
      return '' unless allowed

      url = Rails.application.routes.url_helpers.snow_export_cto_orders_path
      %(<div style="margin-top:12px;">
          <a href="#{url}" class="button" style="font-size:12px;">
            &#11123;&nbsp;Export Orders CSV
          </a>
        </div>).html_safe
    end

    # Issue show page: hide A-B end and optical CFs based on status.
    # Also renders procurement subtask status timeline for tracker-14 issues.
    INVOICE_HUB_ATTACHMENT_CF_IDS = [124, 128, 134, 135].freeze
    TRACKER14_ATTACHMENT_CF_IDS   = [14, 110, 111, 116].freeze

    def view_issues_show_details_bottom(context = {})
      issue = context[:issue]

      # Invoice Hub tracker 12: render CF attachments with standard Redmine preview/thumbnails
      if issue&.tracker_id == 12
        attachments = issue.custom_field_values
          .select { |cfv| INVOICE_HUB_ATTACHMENT_CF_IDS.include?(cfv.custom_field_id) && cfv.value.present? }
          .filter_map { |cfv| Attachment.find_by(id: cfv.value.to_i) }

        return '' unless attachments.any?

        # Hide the plain CF link rows — the preview block below replaces them
        hide_css = INVOICE_HUB_ATTACHMENT_CF_IDS
          .flat_map { |id| [".cf_#{id}.attribute", "p:has(.cf_#{id})"] }
          .join(', ')

        html = "<style>#{hide_css} { display: none !important; }</style>"
        html += context[:controller].render_to_string(
          partial: 'attachments/links',
          locals: {
            container:   issue,
            attachments: attachments,
            options:     { editable: false, deletable: false, author: true },
            thumbnails:  Setting.thumbnails_enabled?
          }
        )
        return html.html_safe
      end

      return '' unless issue&.tracker_id == 14

      output = +''

      hidden_ids = [JUMP_REASON_CF_ID]  # never shown on issue show page — edit form only
      hidden_ids += AB_CF_IDS           unless AB_SHOW_STATUSES.include?(issue.status_id)
      hidden_ids += OPTICAL_CF_IDS      unless OPTICAL_SHOW_STATUSES.include?(issue.status_id)
      hidden_ids += PROJECT_CODE_CF_IDS if     PROJECT_CODE_HIDE_STATUSES.include?(issue.status_id)
      unless hidden_ids.empty?
        selectors = hidden_ids.flat_map { |id| [".cf_#{id}.attribute", "p:has(.cf_#{id})"] }.join(', ')
        output << "<style>#{selectors} { display: none !important; }</style>"
      end

      # BOQ / attachment CF preview block — renders CF attachments with thumbnails
      att_cf_attachments = issue.custom_field_values
        .select { |cfv| TRACKER14_ATTACHMENT_CF_IDS.include?(cfv.custom_field_id) && cfv.value.present? }
        .filter_map { |cfv| Attachment.find_by(id: cfv.value.to_i) }

      if att_cf_attachments.any?
        hide_css = TRACKER14_ATTACHMENT_CF_IDS
          .flat_map { |id| [".cf_#{id}.attribute", "p:has(.cf_#{id})"] }
          .join(', ')
        output << "<style>#{hide_css} { display: none !important; }</style>"
        output << context[:controller].render_to_string(
          partial: 'attachments/links',
          locals: {
            container:   issue,
            attachments: att_cf_attachments,
            options:     { editable: false, deletable: false, author: true },
            thumbnails:  Setting.thumbnails_enabled?
          }
        )
      end

      # Procurement subtask status timeline
      proc_subtasks = issue.children.where(tracker_id: 17).includes(:status, :journals => [:details, :user])
      if proc_subtasks.any?
        output << procurement_subtask_html(proc_subtasks)
      end

      # Retail Redmine sync button — shown when "Send to Retail Redmine" CF is ticked
      output << retail_sync_button_html(issue) if retail_sync_enabled?(issue)

      output.html_safe
    end

    # Issue edit form: provisioning autocomplete + dynamic A-B end field visibility.
    def view_issues_form_details_bottom(context = {})
      issue = context[:issue]

      # Invoice Hub tracker 12: hide clutter fields + conditional CF visibility by Submission Type
      if issue && issue.tracker_id == 12
        proof_of_payment_statuses = [118, 68].to_json
        current_status = (issue.status_id_was || issue.status_id).to_i
        return (<<~HTML).html_safe
          <script>
          (function(){
            var proofStatuses = #{proof_of_payment_statuses};
            var currentStatus = #{current_status};

            function hideRow(el){
              if(!el) return;
              var row = el.closest('p') || el.closest('.attribute') || el;
              if(row) row.style.setProperty('display', 'none', 'important');
            }
            function toggleCf(id, visible){
              document.querySelectorAll('.cf_' + id).forEach(function(el){
                var target = el.closest('p') || el.closest('.attribute') || el;
                target.style.display = visible ? '' : 'none';
              });
            }
            function init(){
              hideRow(document.getElementById('issue_priority_id'));
              hideRow(document.getElementById('issue_assigned_to_id'));
              hideRow(document.getElementById('start_date_area'));
              hideRow(document.getElementById('due_date_area'));

              // Proof of Payment (CF 136): only show at Payment Scheduled or Invoice Paid
              var showProof = proofStatuses.indexOf(currentStatus) !== -1;
              toggleCf(136, showProof);

              // Re-evaluate when status dropdown changes
              var statusSel = document.getElementById('issue_status_id');
              if(statusSel){
                statusSel.addEventListener('change', function(){
                  var sid = parseInt(this.value, 10);
                  toggleCf(136, proofStatuses.indexOf(sid) !== -1);
                });
              }
            }
            if(document.readyState === 'loading'){
              document.addEventListener('DOMContentLoaded', init);
            } else {
              init();
            }
          })();
          </script>
        HTML
      end

      return '' unless issue && [14, 18].include?(issue.tracker_id.to_i)

      output = +''

      # Dynamic show/hide of conditional CFs based on status selection (tracker 14 only).
      if issue.tracker_id == 14
        # Contractor at Site Survey: only CF 14 (Contractor Quotation) should be visible.
        contractor_site_survey = contractor_only_user? && issue.status_id == 24

        output << <<~HTML
          <script>
          (function(){
            var contractorSiteSurvey = #{contractor_site_survey ? 'true' : 'false'};

            var showFromGroups = [
              { showFrom: #{AB_SHOW_STATUSES.to_json},      ids: #{AB_CF_IDS.to_json} },
              { showFrom: #{OPTICAL_SHOW_STATUSES.to_json}, ids: #{OPTICAL_CF_IDS.to_json} }
            ];
            var hideAtGroups = [
              { hideAt: #{PROJECT_CODE_HIDE_STATUSES.to_json}, ids: #{PROJECT_CODE_CF_IDS.to_json} }
            ];
            var t14Seq       = #{TRACKER_14_SEQUENCE.to_json};
            var currentSid   = #{issue.status_id_was || issue.status_id};
            var jumpReasonId = #{JUMP_REASON_CF_ID};
            function toggleCf(id, visible){
              document.querySelectorAll('.cf_' + id).forEach(function(el){
                var target = el.closest('p') || el.closest('.attribute') || el;
                target.style.display = visible ? '' : 'none';
              });
            }
            function toggleGroups(statusId){
              var sid = parseInt(statusId, 10);
              showFromGroups.forEach(function(g){
                var show = g.showFrom.indexOf(sid) !== -1;
                g.ids.forEach(function(id){ toggleCf(id, show); });
              });
              hideAtGroups.forEach(function(g){
                var hide = g.hideAt.indexOf(sid) !== -1;
                g.ids.forEach(function(id){ toggleCf(id, !hide); });
              });
              // Jump Reason: show only when selected status skips steps in the sequence.
              var fromPos = t14Seq.indexOf(currentSid);
              var toPos   = t14Seq.indexOf(sid);
              var isJump  = fromPos !== -1 && toPos !== -1 && toPos > fromPos + 1;
              toggleCf(jumpReasonId, isJump);
            }
            var sel = document.getElementById('issue_status_id');
            if(sel){
              toggleGroups(sel.value);
              sel.addEventListener('change', function(){ toggleGroups(this.value); });
            }

            // Contractor at Site Survey: hide every CF row except CF 14.
            if (contractorSiteSurvey) {
              document.querySelectorAll('p[class*="cf_"], .attribute[class*="cf_"]').forEach(function(row){
                if (!row.classList.contains('cf_14')) {
                  row.style.display = 'none';
                }
              });
            }
          })();
          </script>
        HTML
      end

      # Provisioning autocomplete widget (tracker 14 and 18).
      token = Setting.plugin_redmine_snow_sync['librenms_token'].to_s.strip
      if token.present?
        cf_ids = PROVISIONING_CF_NAMES.transform_values do |name|
          IssueCustomField.find_by(name: name)&.id
        end
        unless cf_ids.values.all?(&:nil?)
          output << context[:controller].render_to_string(
            partial: 'snow_sync/provisioning_autocomplete',
            locals:  { cf_ids: cf_ids }
          )
        end
      end

      output.html_safe
    end

    private

    STATUS_COLORS = {
      71 => '#6c757d',  # Quote Pending — grey
      72 => '#0d6efd',  # PR Raised — blue
      73 => '#198754',  # PR Approved — green
      74 => '#fd7e14',  # PO Generated — orange
      75 => '#20c997',  # Procurement Closed — teal
      91 => '#dc3545',  # Procurement Rejected — red
      92 => '#ffc107',  # P-Returned for Correction — amber
    }.freeze

    def procurement_subtask_html(subtasks)
      rows = subtasks.map do |sub|
        # Build the status history timeline from journals
        history = sub.journals.flat_map do |j|
          j.details.select { |d| d.property == 'attr' && d.prop_key == 'status_id' }.map do |d|
            { date: j.created_on, user: j.user&.name || '—',
              from: IssueStatus.find_by(id: d.old_value)&.name || d.old_value,
              to:   IssueStatus.find_by(id: d.value)&.name || d.value,
              to_id: d.value.to_i }
          end
        end

        color = STATUS_COLORS[sub.status_id] || '#6c757d'
        assignee = sub.assigned_to&.name || '—'

        timeline_html = if history.any?
          steps = history.map do |h|
            c = STATUS_COLORS[h[:to_id]] || '#6c757d'
            %(<span style="display:inline-block;margin:1px 3px;padding:1px 6px;border-radius:3px;
                background:#{c};color:#fff;font-size:0.78em;white-space:nowrap;"
              title="#{h[:date].strftime('%Y-%m-%d %H:%M')} by #{h[:user]}">#{h[:to]}</span>)
          end
          steps.join('<span style="color:#9199aa;margin:0 2px;">›</span>')
        else
          '<span style="color:#9199aa;font-size:0.8em;">No transitions yet</span>'
        end

        %(<tr>
          <td style="padding:4px 6px;"><a href="/issues/#{sub.id}" target="_blank">##{sub.id}</a></td>
          <td style="padding:4px 6px;">
            <span style="display:inline-block;padding:2px 8px;border-radius:3px;
              background:#{color};color:#fff;font-size:0.82em;">#{sub.status.name}</span>
          </td>
          <td style="padding:4px 6px;font-size:0.85em;color:#9199aa;">#{assignee}</td>
          <td style="padding:4px 6px;font-size:0.82em;line-height:1.8;">#{timeline_html}</td>
        </tr>)
      end

      %(<div style="margin-top:16px;border:1px solid #353a45;border-radius:6px;overflow:hidden;">
        <div style="background:#2d3340;padding:6px 10px;font-weight:600;font-size:0.9em;color:#c8cdd6;
          border-bottom:1px solid #353a45;">
          📦 Procurement Subtask#{subtasks.size > 1 ? 's' : ''}
        </div>
        <table style="width:100%;border-collapse:collapse;background:#1e222a;">
          <thead><tr style="border-bottom:1px solid #353a45;font-size:0.8em;color:#9199aa;">
            <th style="padding:4px 6px;text-align:left;">Issue</th>
            <th style="padding:4px 6px;text-align:left;">Current Status</th>
            <th style="padding:4px 6px;text-align:left;">Assigned To</th>
            <th style="padding:4px 6px;text-align:left;">Status Flow</th>
          </tr></thead>
          <tbody>#{rows.join}</tbody>
        </table>
      </div>)
    end

    RETAIL_SYNC_CF_NAME  = 'Send to Retail Redmine'
    RETAIL_REDMINE_URL   = 'http://10.169.62.54'

    def retail_sync_enabled?(issue)
      cf = IssueCustomField.find_by(name: RETAIL_SYNC_CF_NAME)
      return false unless cf
      issue.custom_field_value(cf.id).to_s == '1'
    end

    def retail_sync_button_html(issue)
      # Look up key fields for pre-filling the retail issue
      order_cf  = IssueCustomField.find_by(name: 'Order Number')
      order_num = order_cf ? issue.custom_field_value(order_cf.id).to_s : ''
      retail_cf = IssueCustomField.find_by(name: 'Retail Redmine URL')
      retail_url = retail_cf ? issue.custom_field_value(retail_cf.id).to_s : ''
      already_synced = retail_url.present?

      if already_synced
        %(<div style="margin:12px 0;padding:10px 16px;background:#f0fdf4;border:1px solid #16a34a;border-radius:6px;display:flex;align-items:center;gap:12px;">
          <span style="font-size:18px">&#10003;</span>
          <div>
            <strong style="color:#15803d">Synced to Retail Redmine</strong><br>
            <a href="#{ERB::Util.html_escape(retail_url)}" target="_blank" style="font-size:12px;color:#15803d">#{ERB::Util.html_escape(retail_url)}</a>
          </div>
        </div>)
      else
        %(<div style="margin:12px 0;padding:10px 16px;background:#fefce8;border:1px solid #d97706;border-radius:6px;display:flex;align-items:center;gap:12px;">
          <span style="font-size:20px">&#128279;</span>
          <div style="flex:1">
            <strong style="color:#92400e">Retail Redmine Processing Required</strong><br>
            <span style="font-size:12px;color:#78350f">This order is flagged for the Retail workflow. Create the corresponding issue on the Retail Redmine and paste the link below.</span>
          </div>
          <a href="#{RETAIL_REDMINE_URL}/projects" target="_blank"
             style="padding:7px 16px;background:#d97706;color:#fff;border-radius:5px;font-size:12px;font-weight:700;text-decoration:none;white-space:nowrap;">
            &#8594; Open Retail Redmine
          </a>
        </div>)
      end
    end

    def contractor_only_user?
      return false unless User.current.is_a?(User) && User.current.logged?
      ids = User.current.memberships.flat_map(&:role_ids).uniq
      ids.include?(CONTRACTOR_ROLE_ID) && (ids - [CONTRACTOR_ROLE_ID]).empty?
    end

    def project_manager_for(project)
      project.memberships
             .joins(:roles)
             .where(roles: { id: PROJECTS_DEPT_ROLE_ID })
             .includes(:user)
             .map(&:user)
             .compact
             .first
    end
  end
end
