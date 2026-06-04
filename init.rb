Redmine::Plugin.register :redmine_snow_sync do
  name        'ServiceNow Sync'
  author      'Liquid IT'
  description 'Polls ServiceNow for new Requests and creates Redmine issues with attachments.'
  version     '1.0.0'
  requires_redmine version_or_higher: '5.0.0'

  settings default: {
    'snow_url'          => 'https://oneliquidsupport.service-now.com',
    'snow_username'     => '',
    'snow_password'     => '',
    'target_project_id' => '5',
    'target_tracker_id' => '14',
    'assignment_groups' => 'Zambia Service Delivery,Zambia Technical Services,Zambia Site Survey',
    'poll_states'       => '1,2',
    'poll_delivery_stage' => 'Awaiting acceptance',
    'field_account'     => 'u_account',
    'field_order'       => 'u_order',
    'field_service'     => 'u_service',
    'days_back'         => '7',
    'zmw_usd_rate'            => '27.50',
    'last_sync_at'            => nil,
    'webhook_token'           => '',
    'opportunity_tracker_map' => 'New Business:14,Renewal:14,Upgrade:14,Change:14,Downgrade:14',
    'teams_webhook_url'       => '',
    'teams_test_email'        => ''
  }, partial: 'settings/snow_sync_settings'

  menu :admin_menu, :snow_sync,
       { controller: 'snow_sync_settings', action: 'index' },
       caption: 'ServiceNow Sync'
end

Dir[File.expand_path('lib/snow_sync/*.rb', __dir__)].sort.each { |f| require f }

# SLA timer hook — fires on every issue save
ActiveSupport.on_load(:active_record) do
  Issue.class_eval do
    after_save :record_sla_status_change

    private

    def record_sla_status_change
      return unless saved_change_to_status_id?
      return unless [14, 18].include?(tracker_id)

      old_status_id = saved_change_to_status_id.first

      # SLA timer
      SnowSlaTimer.on_status_change(self, old_status_id)

      # Teams — status change
      SnowSync::TeamsNotifier.notify('status_change', self,
        old_status: IssueStatus.find_by(id: old_status_id)&.name,
        new_status: status.name
      )

      # Teams — rejection (specific event when entering Rejection Pending)
      rejection_status = IssueStatus.find_by(name: 'Rejection Pending')
      if rejection_status && status_id == rejection_status.id
        SnowSync::TeamsNotifier.notify('rejection', self)
      end

    rescue => e
      Rails.logger.error "SnowSLA: hook error on issue ##{id}: #{e.message}"
    end
  end
end
