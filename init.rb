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

  menu :admin_menu, :snow_sf_pipeline,
       { controller: 'snow_sf_pipeline', action: 'index' },
       caption: 'SF Pipeline'

  menu :admin_menu, :snow_checklist_report,
       { controller: 'snow_checklist_report', action: 'index' },
       caption: 'Checklist Compliance'

  menu :admin_menu, :snow_organic_dashboard,
       { controller: 'snow_organic_dashboard', action: 'index' },
       caption: 'Organic Dashboard'
end

Dir[File.expand_path('lib/snow_sync/*.rb', __dir__)].sort.each { |f| require f }


# Wire up controller and model patches (at require time, like other plugins)
IssuesController.prepend    SnowSync::IssueControllerPatch    unless IssuesController.ancestors.include?(SnowSync::IssueControllerPatch)
VersionsController.prepend  SnowSync::VersionsControllerPatch unless VersionsController.ancestors.include?(SnowSync::VersionsControllerPatch)
UsersController.prepend     SnowSync::UsersControllerPatch    unless UsersController.ancestors.include?(SnowSync::UsersControllerPatch)
AdvancedChecklist.prepend   SnowSync::AdvancedChecklistPatch  if defined?(AdvancedChecklist) && !AdvancedChecklist.ancestors.include?(SnowSync::AdvancedChecklistPatch)

# Issue model hooks
ActiveSupport.on_load(:active_record) do
  Issue.class_eval do
    after_save   :snow_sync_after_save
    after_save   :record_sla_status_change
    after_save   :record_procurement_status_change
    after_save   :snow_sync_procurement_auto_assign
    after_save   :snow_sync_splicing_auto_assign
    after_create :populate_procurement_subtask
    validate     :snow_validate_site_survey_gate
    validate     :snow_validate_build_approval_sendback
    validate     :snow_validate_build_approval_gate
    validate     :snow_validate_splicing_gate
    validate     :snow_validate_service_scheduling_gate
    validate     :snow_validate_service_provisioning
    validate     :snow_validate_procurement_transitions
    validate     :snow_validate_stage_jump
    validate     :snow_validate_larkson_jump_comment
    validate     :snow_validate_checklists_completed
    validate     :snow_validate_invoice_paid_gate
    after_save   :snow_invoice_payment_scheduled_notify

    private

    # ── Site Survey → Quote Submission gate ─────────────────────────────────
    # Contractor must upload Contractor Quotation (CF 14).
    # Photo uploads and checklist completion are enforced by the checklist gate.
    def snow_validate_site_survey_gate
      return unless tracker_id == 14 &&
                    status_id_changed? &&
                    status_id == 50 &&   # Quote Submission
                    status_id_was == 24  # Site Survey

      errors.add(:base, 'Contractor Quotation file is required before Quote Submission') unless custom_field_value(14).present?
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

    # ── Build Approval → Fiber Build gate ──────────────────────────────────
    # Procurement subtask must be completed (PO issued) before build can start.
    PROC_CLOSED = 75
    PROC_REJECTED = 91
    def snow_validate_build_approval_gate
      return unless tracker_id == 14 &&
                    status_id_changed? &&
                    status_id == 51 &&   # Fiber Build
                    status_id_was == 90  # Build Approval

      proc_subtasks = children.where(tracker_id: 17)
      if proc_subtasks.empty?
        errors.add(:base, 'No Procurement subtask found — cannot proceed to Fiber Build')
        return
      end

      incomplete = proc_subtasks.where.not(status_id: [PROC_CLOSED, PROC_REJECTED])
      if incomplete.any?
        names = incomplete.map { |s| "##{s.id} (#{s.status.name})" }.join(', ')
        errors.add(:base, "Procurement must be completed before Fiber Build — pending: #{names}")
      end
    end

    # ── Splicing → Quality Assurance gate ────────────────────────────────────
    # Requires optical measurement CFs filled and ≥1 measurement photo.
    def snow_validate_splicing_gate
      filenames = Thread.current[:snow_splicing_filenames]
      return unless filenames
      return unless tracker_id == 14 &&
                    status_id_changed? &&
                    status_id == 52 &&   # Quality Assurance
                    status_id_was == 57  # Splicing

      SnowSync::IssueControllerPatch::OPTICAL_CF_NAMES.each do |cf_name|
        cf  = IssueCustomField.find_by(name: cf_name)
        next unless cf
        val = custom_field_value(cf.id.to_s).to_s.strip
        errors.add(:base, "#{cf_name} is required before Quality Assurance") if val.blank?
      end

      existing_photos = attachments.count { |a| a.filename =~ /\.(jpg|jpeg|png)$/i }
      new_photos      = filenames.count    { |f| f =~ /\.(jpg|jpeg|png)$/i }
      if (existing_photos + new_photos).zero?
        errors.add(:base, 'At least 1 optical measurement photo is required before Quality Assurance')
      end
    end

    # ── Service Scheduling → Contractor Assignment gate ──────────────────────
    # PM must fill Project Code (CF 109), upload KMZ (CF 110) and BOQ (CF 111).
    MEDIA_TYPE_CF_ID = 137
    SERVICE_SCHEDULING_STATUS = 48

    def snow_validate_service_scheduling_gate
      return unless tracker_id == 14 && status_id_changed?

      # Gate 1: entering Service Scheduling — Media Type must be set
      if status_id == SERVICE_SCHEDULING_STATUS
        media = custom_field_value(MEDIA_TYPE_CF_ID).to_s.strip
        errors.add(:base, 'Media Type is required before Service Scheduling') if media.blank?
      end

      # Gate 2: leaving Service Scheduling → Contractor Assignment
      if status_id == 49 && status_id_was == SERVICE_SCHEDULING_STATUS
        project_code = custom_field_value(109).to_s.strip
        errors.add(:base, 'Project Code is required before Contractor Assignment') if project_code.blank?
        errors.add(:base, 'KMZ/KML Site Plan is required before Contractor Assignment') unless custom_field_value(110).present?
        errors.add(:base, 'BOQ Document is required before Contractor Assignment') unless custom_field_value(111).present?
      end
    end

    # ── Checklist completion gate ────────────────────────────────────────────
    # Runs as validate so errors show alongside other gate errors.
    CHECKLIST_GATE_STATUSES = [50, 57].freeze  # PR, Splicing (Organic)
    # Invoice Hub: every forward transition requires the current status checklist to be done
    INVOICE_HUB_CHECKLIST_STATUSES = [62, 64, 44, 67, 118].freeze

    def snow_validate_checklists_completed
      return unless status_id_changed?
      return unless project.module_enabled?('advanced_checklists')

      gate = if tracker_id == 12
               INVOICE_HUB_CHECKLIST_STATUSES.include?(status_id_was)
             else
               CHECKLIST_GATE_STATUSES.include?(status_id)
             end
      return unless gate

      # Find the checklist template(s) that trigger on the status being left,
      # then only count undone items from those specific checklists on this issue.
      template_ids = AdvancedChecklistWorkflow
        .joins(:template)
        .where(status_id: status_id_was)
        .where(advanced_checklist_templates: { tracker_id: tracker_id, deleted: false })
        .pluck(:template_id)

      return if template_ids.empty?

      checklist_ids = AdvancedChecklist
        .where(issue_id: id, deleted: false)
        .joins("INNER JOIN advanced_checklist_items ti ON ti.questionlist_id = advanced_checklists.id")
        .where("EXISTS (SELECT 1 FROM advanced_checklist_template_items WHERE advanced_checklist_template_items.template_id IN (#{template_ids.join(',')}) AND advanced_checklist_template_items.title = ti.title)")
        .pluck(:id)
        .uniq

      # Fall back: use the most recently created checklist on the issue for this status
      if checklist_ids.empty?
        checklist_ids = AdvancedChecklist
          .where(issue_id: id, title: AdvancedChecklists::ChecklistTemplate.where(id: template_ids).pluck(:title), deleted: false)
          .pluck(:id)
      end

      return if checklist_ids.empty?

      undone = AdvancedChecklistItem
        .where(questionlist_id: checklist_ids, done: false, deleted: false)
        .count

      if undone > 0
        current = IssueStatus.find_by(id: status_id_was)&.name || 'current status'
        target  = IssueStatus.find_by(id: status_id)&.name || 'next status'
        errors.add(:base, "All checklist items for '#{current}' must be completed before moving to '#{target}' (#{undone} item#{'s' if undone > 1} remaining)")
      end
    end

    # ── Stage jump restriction ────────────────────────────────────────────────
    # Only Tech Lead or Admin can skip statuses in the defined workflow sequence.
    # A "jump" is any forward move that skips 1 or more sequential steps.
    # SRR(47)→SS(48)→CA(49)→SiteSurvey(24)→PR(50)→BA(90)→FB(51)→Splicing(57)→QA(52)→SD(59)→NOC(53)→CH(60)→BN(61)→Sub(62)→Closed(17)
    TRACKER_14_SEQUENCE = [47, 48, 49, 24, 50, 90, 51, 57, 52, 59, 53, 60, 61, 62, 17].freeze
    TRACKER_18_SEQUENCE = [76, 77, 78, 79, 80, 81, 82, 83].freeze

    def snow_validate_stage_jump
      return unless status_id_changed?
      return unless [14, 18].include?(tracker_id)
      return unless User.current.is_a?(User) && User.current.logged?
      return if User.current.admin?
      return if snow_tech_lead_user?

      seq      = tracker_id == 14 ? TRACKER_14_SEQUENCE : TRACKER_18_SEQUENCE
      from_pos = seq.index(status_id_was)
      to_pos   = seq.index(status_id)
      return if from_pos.nil? || to_pos.nil?  # non-sequential status, always allowed
      return if to_pos <= from_pos + 1          # normal step forward or backward move

      from_name = IssueStatus.find_by(id: status_id_was)&.name || status_id_was.to_s
      to_name   = IssueStatus.find_by(id: status_id)&.name || status_id.to_s

      if snow_projects_dept_user?
        jump_cf = IssueCustomField.find_by(name: 'Jump Reason')
        reason  = jump_cf ? custom_field_value(jump_cf.id).to_s.strip : ''
        return if reason.present?

        errors.add(:base, "Stage jump from '#{from_name}' to '#{to_name}' requires a 'Jump Reason' explaining why " \
                          "no build is required (e.g. in-house installation). Please fill in the Jump Reason field.")
        return
      end

      errors.add(:base, "Stage jump from '#{from_name}' to '#{to_name}' requires approval. " \
                        "Post a comment explaining the reason and ask a Tech Lead or Admin to make this status change.")
    end

    # ── Larkson jump comment requirement ─────────────────────────────────────
    # Larkson (id=18) can jump to any status, but must leave a comment explaining why.
    LARKSON_USER_ID = 18
    def snow_validate_larkson_jump_comment
      return unless User.current.id == LARKSON_USER_ID
      return unless status_id_changed?
      return unless [14, 18].include?(tracker_id)

      seq      = tracker_id == 14 ? TRACKER_14_SEQUENCE : TRACKER_18_SEQUENCE
      from_pos = seq.index(status_id_was)
      to_pos   = seq.index(status_id)
      return if from_pos.nil? || to_pos.nil?
      return if (to_pos - from_pos).abs == 1  # single step forward or backward — no comment needed

      notes = current_journal&.notes.to_s.strip
      if notes.blank?
        from_name = IssueStatus.find_by(id: status_id_was)&.name || status_id_was.to_s
        to_name   = IssueStatus.find_by(id: status_id)&.name || status_id.to_s
        errors.add(:base, "Jumping from '#{from_name}' to '#{to_name}' requires a comment explaining why. Please add a note before saving.")
      end
    end

    def snow_tech_lead_user?
      User.current.memberships.flat_map(&:roles).any? { |r| r.name == 'Tech Lead' }
    end

    def snow_projects_dept_user?
      User.current.memberships.flat_map(&:roles).any? { |r| r.id == 7 }
    end

    # ── Service Delivery → Customer Handover validation ───────────────────────
    # Requires A/B end termination CFs before leaving Service Delivery (tracker 14)
    # or C2 - Provisioning (tracker 18).
    SERVICE_PROVISIONING_TRANSITIONS = {
      14 => { from: 59, to: 60, label: 'Customer Handover' },  # Service Delivery → Customer Handover
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

      # Contractor-Assignment: capture PM, then auto-assign to Boas for contractor selection
      if status_id == 49
        boas       = User.find_by(id: 199)
        sys_user   = User.where(admin: true).first
        pm_id      = saved_changes[:assigned_to_id]&.first || assigned_to_id
        SnowIssuePm.find_or_create_by(issue_id: id) { |r| r.pm_user_id = pm_id }
        update_column(:assigned_to_id, 199)
        journals.create!(user: sys_user, notes: '') do |j|
          j.details.build(property: 'attr', prop_key: 'assigned_to_id',
                          old_value: pm_id, value: 199)
        end
        journals.create!(user: sys_user,
          notes: "🔁 Auto-assigned to *#{boas&.name || 'Boas Katanga'}* to select a contractor.")
        Rails.logger.info "SnowSync: issue ##{id} → Contractor-Assignment (PM ##{pm_id} stored, assigned to Boas)"

      # → Site Survey: record contractor name in CF 58 (read-only reference field)
      elsif status_id == 24 && tracker_id == 14
        contractor = User.find_by(id: assigned_to_id)
        if contractor
          cf58 = IssueCustomField.find_by(id: 58)
          if cf58
            cv = custom_values.find_or_initialize_by(custom_field_id: 58)
            cv.update_column(:value, contractor.name) if cv.persisted? || cv.save(validate: false)
            Rails.logger.info "SnowSync: issue ##{id} → Site Survey — Contractor Name set to #{contractor.name}"
          end
        end

      # Site Survey → Quote Submission: store contractor, assign to stored PM
      elsif status_id == 50 && saved_changes[:status_id]&.first == 24
        contractor_id = assigned_to_id
        contractor    = User.find_by(id: contractor_id)
        pm_rec        = SnowIssuePm.find_by(issue_id: id)
        pm            = pm_rec&.pm_user_id ? User.find_by(id: pm_rec.pm_user_id) : nil
        pm_id         = pm&.id || 17
        system_user   = User.where(admin: true).first
        SnowBuildApprovalContractor.upsert({ issue_id: id, contractor_id: contractor_id },
                                            unique_by: :issue_id) if contractor_id
        update_column(:assigned_to_id, pm_id)
        journals.create!(user: system_user, notes: '') do |j|
          j.details.build(property: 'attr', prop_key: 'assigned_to_id',
                          old_value: contractor_id, value: pm_id)
        end
        journals.create!(user: system_user,
          notes: "🔁 Site Survey complete — auto-assigned to PM *#{pm&.name || 'Project Manager'}* for Purchase Requisition. Contractor *#{contractor&.name}* stored.")
        Rails.logger.info "SnowSync: issue ##{id} → Purchase Requisition (contractor ##{contractor_id} stored, assigned to PM ##{pm_id})"

      # Build Approval: store contractor, assign to stored PM
      elsif status_id == 90
        contractor_id = assigned_to_id
        contractor    = User.find_by(id: contractor_id)
        pm_rec        = SnowIssuePm.find_by(issue_id: id)
        pm            = pm_rec&.pm_user_id ? User.find_by(id: pm_rec.pm_user_id) : nil
        pm_id         = pm&.id || 17  # fallback to Musonda if PM not recorded
        system_user   = User.where(admin: true).first
        SnowBuildApprovalContractor.upsert({ issue_id: id, contractor_id: contractor_id },
                                            unique_by: :issue_id) if contractor_id
        update_column(:assigned_to_id, pm_id)
        journals.create!(user: system_user, notes: '') do |j|
          j.details.build(property: 'attr', prop_key: 'assigned_to_id',
                          old_value: contractor_id, value: pm_id)
        end
        journals.create!(user: system_user,
          notes: "🔁 Auto-assigned to PM *#{pm&.name || 'Project Manager'}* for Build Approval review. Contractor #{contractor&.name} stored and will be restored on approval.")
        Rails.logger.info "SnowSync: issue ##{id} → Build Approval (contractor ##{contractor_id} stored, assigned to PM ##{pm_id})"

      # Build Approved → Fiber Build: restore contractor
      elsif status_id == 51 && saved_changes[:status_id]&.first == 90
        rec = SnowBuildApprovalContractor.find_by(issue_id: id)
        if rec&.contractor_id
          contractor  = User.find_by(id: rec.contractor_id)
          system_user = User.where(admin: true).first
          pm_id       = assigned_to_id
          update_column(:assigned_to_id, rec.contractor_id)
          journals.create!(user: system_user, notes: '') do |j|
            j.details.build(property: 'attr', prop_key: 'assigned_to_id',
                            old_value: pm_id, value: rec.contractor_id)
          end
          journals.create!(user: system_user,
            notes: "🔁 Build Approved — auto-reassigned to contractor *#{contractor&.name}* for Fiber Build.")
          Rails.logger.info "SnowSync: issue ##{id} → Fiber Build approved (contractor ##{rec.contractor_id} restored)"
        end

      # Build Approval send-back → Quote Submission: restore contractor
      elsif status_id == 50 && saved_changes[:status_id]&.first == 90
        rec = SnowBuildApprovalContractor.find_by(issue_id: id)
        if rec&.contractor_id
          contractor  = User.find_by(id: rec.contractor_id)
          system_user = User.where(admin: true).first
          pm_id       = assigned_to_id
          update_column(:assigned_to_id, rec.contractor_id)
          journals.create!(user: system_user, notes: '') do |j|
            j.details.build(property: 'attr', prop_key: 'assigned_to_id',
                            old_value: pm_id, value: rec.contractor_id)
          end
          journals.create!(user: system_user,
            notes: "🔁 Sent back for revision — reassigned to contractor *#{contractor&.name}* to address feedback.")
          Rails.logger.info "SnowSync: issue ##{id} → PR send-back (contractor ##{rec.contractor_id} restored)"
        end

      # Service Delivery: auto-assign to Larkson Chibesa
      elsif status_id == 59 && tracker_id == 14
        larkson     = User.find_by(login: 'Chib636')
        system_user = User.where(admin: true).first
        old_assignee = assigned_to_id
        if larkson
          update_column(:assigned_to_id, larkson.id)
          journals.create!(user: system_user, notes: '') do |j|
            j.details.build(property: 'attr', prop_key: 'assigned_to_id',
                            old_value: old_assignee, value: larkson.id)
          end
          journals.create!(user: system_user,
            notes: "🔁 Auto-assigned to *#{larkson.name}* for Service Delivery.")
          Rails.logger.info "SnowSync: issue ##{id} → Service Delivery (assigned to #{larkson.login})"
        end
      end
    end

    def record_sla_status_change
      return unless saved_change_to_status_id?
      return unless [14, 17, 18].include?(tracker_id)

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

    # ── Splicing → auto-assign to Jeffrey Kampamba (unless PM handles own order) ──
    # Arthur (170), Hameja (177), Ian (31), James Mugala (172), Victor Chimovu (171)
    # manage their own orders — if currently assigned to one of them, leave unchanged.
    # All others → Jeffrey Kampamba (178).
    SPLICING_SELF_MANAGED = [170, 177, 31, 172, 171].freeze

    def snow_sync_splicing_auto_assign
      return unless tracker_id == 14
      return unless saved_change_to_status_id?
      return unless status_id == 57  # Splicing
      return if SPLICING_SELF_MANAGED.include?(assigned_to_id)

      jeffrey     = User.find_by(id: 178)
      return unless jeffrey
      system_user = User.where(admin: true).first
      old_assignee = assigned_to_id
      update_column(:assigned_to_id, 178)
      journals.create!(user: system_user, notes: '') do |j|
        j.details.build(property: 'attr', prop_key: 'assigned_to_id', old_value: old_assignee, value: 178)
      end
      Rails.logger.info "SnowSync: Issue ##{id} → Splicing, auto-assigned to Jeffrey (#178)"
    rescue => e
      Rails.logger.error "SnowSync: splicing_auto_assign failed for ##{id}: #{e.message}"
    end

    # ── Procurement PR Approved → auto-assign to Boas Katanga ────────────────
    # When a Procurement subtask (tracker 17) reaches PR Approved (73),
    # automatically reassign to Boas Katanga (id=53) for PO generation.
    def snow_sync_procurement_auto_assign
      return unless tracker_id == 17
      return unless saved_change_to_status_id?
      return unless status_id == 73  # PR Approved

      boas        = User.find_by(id: 199)
      system_user = User.where(admin: true).first
      old_assignee = assigned_to_id
      update_column(:assigned_to_id, 199)
      journals.create!(user: system_user, notes: '') do |j|
        j.details.build(property: 'attr', prop_key: 'assigned_to_id', old_value: old_assignee, value: 199)
      end
      journals.create!(user: system_user,
        notes: "🔁 PR Approved — auto-assigned to *#{boas&.name || 'Boas Katanga'}* for PO Generation.")
      Rails.logger.info "SnowSync: Procurement ##{id} PR Approved → assigned to Boas (#199)"
    rescue => e
      Rails.logger.error "SnowSync: procurement_auto_assign failed for ##{id}: #{e.message}"
    end

    # ── Procurement subtask population ───────────────────────────────────────
    # Fires when a new Procurement subtask (tracker 17) is created.
    # Copies material CF quantities from the parent Commercial Order and assigns
    # the issue to the stored PM so they can verify before raising a PR.
    def populate_procurement_subtask
      return unless tracker_id == 17
      return unless parent_id.present?
      par = Issue.find_by(id: parent_id)
      return unless par&.tracker_id == 14

      available_cf_ids = available_custom_fields.map { |cf| cf.id.to_s }.to_set
      cf_updates = {}
      [91, 92, 93, 94, 95, 96].each do |cf_id|
        next unless available_cf_ids.include?(cf_id.to_s)
        val = par.custom_field_value(cf_id.to_s).to_s.strip
        cf_updates[cf_id.to_s] = val if val.present?
      end

      self.assigned_to_id = 57  # Deborah Chisenga handles initial procurement review
      self.custom_field_values = cf_updates unless cf_updates.empty?
      save(validate: false)
      Rails.logger.info "SnowSync: Procurement subtask ##{id} populated from parent ##{par.id} (assigned to Deborah #57)"
    rescue => e
      Rails.logger.error "SnowSync: populate_procurement_subtask failed for ##{id}: #{e.message}"
    end

    # ── Invoice Hub: require Proof of Payment before Invoice Paid ────────────
    def snow_validate_invoice_paid_gate
      return unless tracker_id == 12
      return unless status_id_changed? && status_id == 68
      unless custom_field_value(136).present?
        errors.add(:base, 'Proof of Payment must be uploaded before marking as Invoice Paid')
      end
    end

    # ── Invoice Hub: email issue author when Payment Scheduled ───────────────
    def snow_invoice_payment_scheduled_notify
      return unless tracker_id == 12
      return unless saved_change_to_status_id? && status_id == 118

      author_email = author&.email_address&.address
      return if author_email.blank?

      SnowSyncMailer.invoice_payment_scheduled(
        author_email,
        author_name:    author.firstname,
        issue:          self,
        po_number:      custom_field_value(67).to_s.strip,
        invoice_amount: custom_field_value(65).to_s.strip,
        invoice_date:   custom_field_value(68).to_s.strip,
        submission_type: custom_field_value(122).to_s.strip
      ).deliver_now
      Rails.logger.info "SnowSync: Payment Scheduled email sent to #{author_email} for invoice hub issue ##{id}"
    rescue => e
      Rails.logger.error "SnowSync: Payment Scheduled email failed for issue ##{id}: #{e.message}"
    end

    # ── Procurement gate validations ──────────────────────────────────────────
    def snow_validate_procurement_transitions
      return unless tracker_id == 17
      return unless status_id_changed?

      # Quote Pending (71) → PR Raised (72): PR Reference (CF 86) required
      if status_id_was == 71 && status_id == 72
        val = custom_field_value(86).to_s.strip
        errors.add(:base, 'PR Reference number must be entered before moving to PR Raised') if val.blank?
      end

      # PR Approved (73) → PO Generated (74): PO Number (CF 13) + Purchase Order PDF (CF 87) required
      if status_id_was == 73 && status_id == 74
        po_num = custom_field_value(13).to_s.strip
        errors.add(:base, 'PO Number must be entered before moving to PO Generated') if po_num.blank?
        errors.add(:base, 'Purchase Order PDF must be uploaded before moving to PO Generated') unless custom_field_value(87).present?
      end
    end

    # ── Procurement Closed: email contractor with PO ──────────────────────────
    def record_procurement_status_change
      return unless tracker_id == 17
      return unless saved_change_to_status_id?
      return unless status_id == 75  # Procurement Closed

      par = parent_id ? Issue.find_by(id: parent_id) : nil
      return unless par

      contractor_rec = SnowBuildApprovalContractor.find_by(issue_id: par.id)
      return unless contractor_rec&.contractor_id

      contractor = User.find_by(id: contractor_rec.contractor_id)
      return unless contractor

      email = contractor.email_address&.address
      return if email.blank?

      po_number = custom_field_value(13).to_s.strip
      po_att_id = custom_field_value(87).to_i
      po_pdf    = Attachment.find_by(id: po_att_id) || attachments.select { |a| a.filename =~ /\.pdf$/i }.last

      SnowSyncMailer.procurement_closed_notification(
        email,
        contractor_name: contractor.name,
        issue:           self,
        parent_issue:    par,
        po_number:       po_number,
        po_pdf:          po_pdf
      ).deliver_now
      Rails.logger.info "SnowSync: Procurement Closed email sent to #{email} for issue ##{id}"
    rescue => e
      Rails.logger.error "SnowSync: Procurement Closed email failed for issue ##{id}: #{e.message}"
    end
  end
end
