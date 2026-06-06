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

# Wire up controller and model patches
Rails.configuration.to_prepare do
  IssuesController.prepend SnowSync::IssueControllerPatch

  # Patch AdvancedChecklist to auto-assign checklist items to the issue's assignee
  if defined?(AdvancedChecklist)
    AdvancedChecklist.prepend SnowSync::AdvancedChecklistPatch
  end
end

# Issue model hooks
ActiveSupport.on_load(:active_record) do
  Issue.class_eval do
    after_save :snow_sync_after_save
    after_save :record_sla_status_change
    validate   :snow_validate_pr_transition
    validate   :snow_validate_build_approval_sendback

    private

    # ── Purchase-Requisition transition validation ────────────────────────────
    # Runs on every save; only active during Contractor-Assignment → PR transition
    # (thread-local set by IssueControllerPatch#update)
    def snow_validate_pr_transition
      filenames = Thread.current[:snow_pr_filenames]
      return unless filenames  # not a guarded transition

      return unless tracker_id == 14 &&
                    status_id_changed? &&
                    status_id == 50 &&   # Purchase-Requisition
                    status_id_was == 49  # Contractor-Assignment

      # 1. All material CFs must be filled in
      SnowSync::IssueControllerPatch::MATERIAL_CF_NAMES.each do |cf_name|
        cf  = IssueCustomField.find_by(name: cf_name)
        next unless cf
        val = custom_field_value(cf.id.to_s).to_s.strip
        errors.add(:base, "#{cf_name} is required before submitting to Purchase-Requisition") if val.blank?
      end

      # 2. At least 5 photos (jpg / png)
      photos = filenames.count { |f| f =~ /\.(jpg|jpeg|png)$/i }
      if photos < 5
        errors.add(:base, "At least 5 site photos (JPG/PNG) are required — #{photos} attached")
      end

      # 3. At least 1 PDF quote
      pdfs = filenames.count { |f| f =~ /\.pdf$/i }
      errors.add(:base, 'A contractor quote (PDF) must be attached') if pdfs.zero?
    end

    # ── Build Approval send-back validation ───────────────────────────────────
    def snow_validate_build_approval_sendback
      return unless Thread.current[:snow_build_approval_sendback] == id
      return unless tracker_id == 14 &&
                    status_id_changed? &&
                    status_id == 50 &&   # Purchase-Requisition
                    status_id_was == 90  # Build Approval

      notes = current_journal&.notes.to_s.strip
      if notes.blank?
        errors.add(:base, 'A comment explaining what needs to be corrected is required when sending back for revision')
      end
    end

    # ── After-save hooks ──────────────────────────────────────────────────────
    def snow_sync_after_save
      return unless [14, 18].include?(tracker_id)

      # Auto-assign target version based on due_date
      if saved_change_to_due_date? || (fixed_version_id.nil? && due_date.present?)
        SnowSync::VersionManager.auto_assign(self)
      end

      return unless saved_change_to_status_id?

      # Build Approval auto-assign + contractor handoff
      if status_id == 90  # → Build Approval: store contractor, assign Musonda
        contractor_id = assigned_to_id
        SnowBuildApprovalContractor.upsert({ issue_id: id, contractor_id: contractor_id },
                                            unique_by: :issue_id) if contractor_id
        update_column(:assigned_to_id, 17)
        Rails.logger.info "SnowSync: issue ##{id} → Build Approval (contractor ##{contractor_id} stored, assigned to Musonda)"

      elsif status_id == 51 && status_id_was == 90  # Build Approved → Fiber Build: restore contractor
        rec = SnowBuildApprovalContractor.find_by(issue_id: id)
        if rec&.contractor_id
          update_column(:assigned_to_id, rec.contractor_id)
          Rails.logger.info "SnowSync: issue ##{id} → Fiber Build (reassigned to contractor ##{rec.contractor_id})"
        end
      end
    end

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

      # Teams — rejection
      rejection_status = IssueStatus.find_by(name: 'Rejection Pending')
      if rejection_status && status_id == rejection_status.id
        SnowSync::TeamsNotifier.notify('rejection', self)
      end

    rescue => e
      Rails.logger.error "SnowSLA: hook error on issue ##{id}: #{e.message}"
    end
  end
end
