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

    # Hides the existing attachments list for contractor-only users.
    # The upload widget (#attachments_fields) uses a different selector and stays visible.
    def view_layouts_base_html_head(context = {})
      return '' unless contractor_only_user?

      '<style>.attachments { display: none !important; }</style>'.html_safe
    end

    def view_issues_form_details_bottom(context = {})
      issue = context[:issue]
      return '' unless issue && [14, 18].include?(issue.tracker_id.to_i)

      token = Setting.plugin_redmine_snow_sync['librenms_token'].to_s.strip
      return '' if token.blank?

      cf_ids = PROVISIONING_CF_NAMES.transform_values do |name|
        IssueCustomField.find_by(name: name)&.id
      end
      return '' if cf_ids.values.all?(&:nil?)

      context[:controller].render_to_string(
        partial: 'snow_sync/provisioning_autocomplete',
        locals:  { cf_ids: cf_ids }
      )
    end

    private

    def contractor_only_user?
      return false unless User.current.is_a?(User) && User.current.logged?
      ids = User.current.memberships.flat_map(&:role_ids).uniq
      ids.include?(CONTRACTOR_ROLE_ID) && (ids - [CONTRACTOR_ROLE_ID]).empty?
    end
  end
end
