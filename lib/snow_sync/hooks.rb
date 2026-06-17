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

    # A-B end termination CFs — only visible from Service Delivery (59) onwards.
    AB_CF_IDS        = [98, 99, 100, 101, 102, 103, 104, 105].freeze
    AB_SHOW_STATUSES = [59, 60, 61, 62, 17].freeze

    # Optical measurement CFs — only visible from Splicing (57) onwards.
    OPTICAL_CF_IDS        = [106, 107, 108].freeze
    OPTICAL_SHOW_STATUSES = [57, 59, 60, 61, 62, 17].freeze

    # Project Code CF — visible from Service Scheduling (48) onwards; hidden at Service Request Review.
    PROJECT_CODE_CF_IDS        = [109].freeze
    PROJECT_CODE_HIDE_STATUSES = [47, 1, 7].freeze  # Service Request Review and earlier intake statuses

    # Hides the existing attachments list for contractor-only users.
    # The upload widget (#attachments_fields) uses a different selector and stays visible.
    def view_layouts_base_html_head(context = {})
      return '' unless contractor_only_user?

      '<style>.attachments { display: none !important; }</style>'.html_safe
    end

    # Issue show page: hide A-B end and optical CFs based on status.
    # Also renders procurement subtask status timeline for tracker-14 issues.
    def view_issues_show_details_bottom(context = {})
      issue = context[:issue]
      return '' unless issue&.tracker_id == 14

      output = +''

      hidden_ids = []
      hidden_ids += AB_CF_IDS           unless AB_SHOW_STATUSES.include?(issue.status_id)
      hidden_ids += OPTICAL_CF_IDS      unless OPTICAL_SHOW_STATUSES.include?(issue.status_id)
      hidden_ids += PROJECT_CODE_CF_IDS if     PROJECT_CODE_HIDE_STATUSES.include?(issue.status_id)
      unless hidden_ids.empty?
        selectors = hidden_ids.map { |id| "tr:has(td.cf_#{id})" }.join(', ')
        output << "<style>#{selectors} { display: none !important; }</style>"
      end

      # Procurement subtask status timeline
      proc_subtasks = issue.children.where(tracker_id: 17).includes(:status, :journals => [:details, :user])
      if proc_subtasks.any?
        output << procurement_subtask_html(proc_subtasks)
      end

      output.html_safe
    end

    # Issue edit form: provisioning autocomplete + dynamic A-B end field visibility.
    def view_issues_form_details_bottom(context = {})
      issue = context[:issue]
      return '' unless issue && [14, 18].include?(issue.tracker_id.to_i)

      output = +''

      # Dynamic show/hide of conditional CFs based on status selection (tracker 14 only).
      if issue.tracker_id == 14
        output << <<~HTML
          <script>
          (function(){
            var showFromGroups = [
              { showFrom: #{AB_SHOW_STATUSES.to_json},      ids: #{AB_CF_IDS.to_json} },
              { showFrom: #{OPTICAL_SHOW_STATUSES.to_json}, ids: #{OPTICAL_CF_IDS.to_json} }
            ];
            var hideAtGroups = [
              { hideAt: #{PROJECT_CODE_HIDE_STATUSES.to_json}, ids: #{PROJECT_CODE_CF_IDS.to_json} }
            ];
            function toggleGroups(statusId){
              var sid = parseInt(statusId, 10);
              showFromGroups.forEach(function(g){
                var show = g.showFrom.indexOf(sid) !== -1;
                g.ids.forEach(function(id){
                  document.querySelectorAll('.cf_' + id).forEach(function(el){
                    el.style.display = show ? '' : 'none';
                  });
                });
              });
              hideAtGroups.forEach(function(g){
                var hide = g.hideAt.indexOf(sid) !== -1;
                g.ids.forEach(function(id){
                  document.querySelectorAll('.cf_' + id).forEach(function(el){
                    el.style.display = hide ? 'none' : '';
                  });
                });
              });
            }
            var sel = document.getElementById('issue_status_id');
            if(sel){
              toggleGroups(sel.value);
              sel.addEventListener('change', function(){ toggleGroups(this.value); });
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

    def contractor_only_user?
      return false unless User.current.is_a?(User) && User.current.logged?
      ids = User.current.memberships.flat_map(&:role_ids).uniq
      ids.include?(CONTRACTOR_ROLE_ID) && (ids - [CONTRACTOR_ROLE_ID]).empty?
    end
  end
end
