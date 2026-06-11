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

    # IDs of the A-B end termination CFs — only visible from Service Delivery (59) onwards.
    AB_CF_IDS        = [98, 99, 100, 101, 102, 103, 104, 105].freeze
    AB_SHOW_STATUSES = [59, 60, 61, 53, 17].freeze

    # Hides the existing attachments list for contractor-only users.
    # The upload widget (#attachments_fields) uses a different selector and stays visible.
    def view_layouts_base_html_head(context = {})
      return '' unless contractor_only_user?

      '<style>.attachments { display: none !important; }</style>'.html_safe
    end

    # Issue show page: hide A-B end CF rows if status is before Service Delivery.
    def view_issues_show_details_bottom(context = {})
      issue = context[:issue]
      return '' unless issue&.tracker_id == 14
      return '' if AB_SHOW_STATUSES.include?(issue.status_id)

      selectors = AB_CF_IDS.map { |id| "tr:has(td.cf_#{id})" }.join(', ')
      "<style>#{selectors} { display: none !important; }</style>".html_safe
    end

    # Issue edit form: provisioning autocomplete + dynamic A-B end field visibility.
    def view_issues_form_details_bottom(context = {})
      issue = context[:issue]
      return '' unless issue && [14, 18].include?(issue.tracker_id.to_i)

      output = +''

      # Dynamic show/hide of A-B end CFs based on status selection (tracker 14 only).
      if issue.tracker_id == 14
        output << <<~HTML
          <script>
          (function(){
            var showFrom = #{AB_SHOW_STATUSES.to_json};
            var cfIds    = #{AB_CF_IDS.to_json};
            function toggleAbFields(statusId){
              var show = showFrom.indexOf(parseInt(statusId, 10)) !== -1;
              cfIds.forEach(function(id){
                document.querySelectorAll('.cf_' + id).forEach(function(el){
                  el.style.display = show ? '' : 'none';
                });
              });
            }
            var sel = document.getElementById('issue_status_id');
            if(sel){
              toggleAbFields(sel.value);
              sel.addEventListener('change', function(){ toggleAbFields(this.value); });
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

    def contractor_only_user?
      return false unless User.current.is_a?(User) && User.current.logged?
      ids = User.current.memberships.flat_map(&:role_ids).uniq
      ids.include?(CONTRACTOR_ROLE_ID) && (ids - [CONTRACTOR_ROLE_ID]).empty?
    end
  end
end
