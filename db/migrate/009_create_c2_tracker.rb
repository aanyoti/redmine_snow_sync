class CreateC2Tracker < ActiveRecord::Migration[7.0]
  C2_STATUSES = [
    { name: 'C2 - Service Request Review', default_done_ratio: 10,  is_closed: false },
    { name: 'C2 - Technical Assessment',   default_done_ratio: 25,  is_closed: false },
    { name: 'C2 - Provisioning',           default_done_ratio: 45,  is_closed: false },
    { name: 'C2 - Configuration & Testing',default_done_ratio: 65,  is_closed: false },
    { name: 'C2 - UAT',                    default_done_ratio: 80,  is_closed: false },
    { name: 'C2 - Handover',               default_done_ratio: 90,  is_closed: false },
    { name: 'C2 - Billing',                default_done_ratio: 95,  is_closed: true  },
    { name: 'C2 - Closed',                 default_done_ratio: 100, is_closed: true  },
    { name: 'C2 - Rejected',               default_done_ratio: 100, is_closed: true  },
  ].freeze

  SERVICE_TYPE_VALUES = %w[
    VoIP
    M365
    Cloud\ -\ Azure
    Cloud\ -\ AWS
    Cloud\ -\ Google
    Cybersecurity
    Cloud\ PBX
    Licensing
    Other\ Cloud
  ].freeze

  def up
    # ── Statuses ──────────────────────────────────────────────────────────
    status_ids = {}
    C2_STATUSES.each do |attrs|
      s = IssueStatus.find_or_create_by!(name: attrs[:name]) do |st|
        st.default_done_ratio = attrs[:default_done_ratio]
        st.is_closed          = attrs[:is_closed]
      end
      status_ids[attrs[:name]] = s.id
    end

    # ── Tracker ───────────────────────────────────────────────────────────
    default_status = IssueStatus.find(status_ids['C2 - Service Request Review'])
    tracker = Tracker.create!(
      name:             'C2',
      is_in_roadmap:    true,
      fields_bits:      0,
      default_status:   default_status
    )

    project = Project.find(5)
    project.trackers << tracker unless project.trackers.include?(tracker)

    # ── Workflow — all transitions for all non-builtin roles ───────────────
    all_ids   = status_ids.values
    role_ids  = Role.where(builtin: 0).pluck(:id)
    role_ids.each do |role_id|
      all_ids.each do |from_id|
        all_ids.each do |to_id|
          next if from_id == to_id
          WorkflowTransition.find_or_create_by!(
            tracker_id:    tracker.id,
            old_status_id: from_id,
            new_status_id: to_id,
            role_id:       role_id,
            type:          'WorkflowTransition'
          )
        end
      end
    end

    # ── Service Type custom field ─────────────────────────────────────────
    service_type_cf = IssueCustomField.create!(
      name:            'Service Type',
      field_format:    'list',
      is_required:     false,
      is_for_all:      false,
      possible_values: SERVICE_TYPE_VALUES.join("\n"),
      position:        99
    )
    service_type_cf.trackers << tracker
    service_type_cf.projects << project
    service_type_cf.save!

    # ── Services custom field (multi-component consolidation) ─────────────
    services_cf = IssueCustomField.create!(
      name:         'Services',
      field_format: 'text',
      is_required:  false,
      is_for_all:   false,
      position:     100
    )
    services_cf.trackers << tracker
    services_cf.projects << project
    services_cf.save!

    say "C2 tracker created (id=#{tracker.id})"
    say "Service Type CF id=#{service_type_cf.id}"
    say "Services CF id=#{services_cf.id}"
    say "Statuses: #{status_ids.inspect}"
  end

  def down
    tracker = Tracker.find_by(name: 'C2')
    if tracker
      WorkflowTransition.where(tracker_id: tracker.id).delete_all
      tracker.destroy
    end
    IssueStatus.where("name LIKE 'C2 - %'").destroy_all
    IssueCustomField.find_by(name: 'Service Type')&.destroy
    IssueCustomField.find_by(name: 'Services')&.destroy
  end
end
