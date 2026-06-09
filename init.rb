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
    'teams_test_email'        => '',
    'active_wip_groups'       => 'Service Delivery,Projects',
    'librenms_token'          => 'e509511c70df0659cea1f1feccb8b0ac'
  }, partial: 'settings/snow_sync_settings'

  menu :admin_menu, :snow_sync,
       { controller: 'snow_sync_settings', action: 'index' },
       caption: 'ServiceNow Sync'

  menu :admin_menu, :snow_sla_report,
       { controller: 'snow_sla_report', action: 'index' },
       caption: 'SLA Report'

  menu :admin_menu, :snow_monthly_target,
       { controller: 'snow_monthly_target', action: 'index' },
       caption: 'Monthly Target'
end

Dir[File.expand_path('lib/snow_sync/*.rb', __dir__)].sort.each { |f| require f }

Redmine::Hook.add_listener(SnowSync::Hooks)

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
    validate   :snow_validate_service_provisioning

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

    # ── Service Provisioning → Sign Off validation ───────────────────────────
    # Requires A/B end fields before leaving Service Provisioning (tracker 14)
    # or C2 - Provisioning (tracker 18).
    SERVICE_PROVISIONING_TRANSITIONS = {
      14 => { from: 14, to: 15, label: 'Sign Off' },   # Service Provisioning → Sign Off
      18 => { from: 78, to: 79, label: 'C2 - Configuration & Testing' },
    }.freeze
    SERVICE_PROVISIONING_CF_NAMES = [
      'A-End Termination POP', 'A-End Switch/Router', 'A-End Termination Port',
      'B-End Termination POP', 'B-End Switch/Router', 'B-End Termination Port',
      'VLAN/IP', 'Bandwidth Capacity',
    ].freeze

    def snow_validate_service_provisioning
      return unless status_id_changed?
      t = SERVICE_PROVISIONING_TRANSITIONS[tracker_id]
      return unless t
      return unless status_id_was == t[:from] && status_id == t[:to]

      SERVICE_PROVISIONING_CF_NAMES.each do |cf_name|
        cf  = IssueCustomField.find_by(name: cf_name)
        next unless cf
        val = custom_field_value(cf.id.to_s).to_s.strip
        errors.add(:base, "#{cf_name} is required before moving to #{t[:label]}") if val.blank?
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
        contractor    = User.find_by(id: contractor_id)
        musonda       = User.find_by(id: 17)
        SnowBuildApprovalContractor.upsert({ issue_id: id, contractor_id: contractor_id },
                                            unique_by: :issue_id) if contractor_id
        update_column(:assigned_to_id, 17)
        system_user = User.find_by(admin: true)
        journals.create!(user: system_user, notes: '') do |j|
          j.details.build(property: 'attr', prop_key: 'assigned_to_id',
                          old_value: contractor_id, value: 17)
        end
        journals.create!(user: system_user,
          notes: "🔁 Auto-assigned to *#{musonda&.name || 'Build Approver'}* for Build Approval review. Previous assignee #{contractor&.name} stored and will be restored on approval.")
        Rails.logger.info "SnowSync: issue ##{id} → Build Approval (contractor ##{contractor_id} stored, assigned to Musonda)"

      elsif status_id == 51 && status_id_was == 90  # Build Approved → Fiber Build: restore contractor
        rec        = SnowBuildApprovalContractor.find_by(issue_id: id)
        if rec&.contractor_id
          contractor   = User.find_by(id: rec.contractor_id)
          system_user  = User.find_by(admin: true)
          update_column(:assigned_to_id, rec.contractor_id)
          journals.create!(user: system_user, notes: '') do |j|
            j.details.build(property: 'attr', prop_key: 'assigned_to_id',
                            old_value: 17, value: rec.contractor_id)
          end
          journals.create!(user: system_user,
            notes: "🔁 Auto-reassigned to contractor *#{contractor&.name}* for Fiber Build.")
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
