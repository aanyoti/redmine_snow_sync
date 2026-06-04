class CommercialWorkflowStatuses < ActiveRecord::Migration[7.0]
  NEW_STATUSES = [
    { name: 'On Hold - Materials',  default_done_ratio: nil, is_closed: false },
    { name: 'On Hold - Technical',  default_done_ratio: nil, is_closed: false },
    { name: 'On Hold - Customer',   default_done_ratio: nil, is_closed: false },
    { name: 'Rejection Pending',    default_done_ratio: nil, is_closed: false },
    { name: 'Closed - Rejected',    default_done_ratio: 100, is_closed: true  },
    { name: 'Build Approval',       default_done_ratio: 50,  is_closed: false },
  ].freeze

  TRACKER_IDS = [14].freeze  # Commercial Orders — C2 added separately when workflow is confirmed

  def up
    status_ids = {}
    NEW_STATUSES.each do |attrs|
      s = IssueStatus.find_or_create_by!(name: attrs[:name]) do |st|
        st.default_done_ratio = attrs[:default_done_ratio]
        st.is_closed          = attrs[:is_closed]
      end
      status_ids[attrs[:name]] = s.id
      say "Status '#{attrs[:name]}' id=#{s.id}"
    end

    # Add transitions: all existing Commercial statuses ↔ new On Hold statuses
    # and Service Request Review → Rejection Pending → Closed-Rejected
    role_ids        = Role.where(builtin: 0).pluck(:id)
    existing_ids    = WorkflowTransition.where(tracker_id: 14)
                        .pluck(:old_status_id, :new_status_id).flatten.uniq
    on_hold_ids     = [
      status_ids['On Hold - Materials'],
      status_ids['On Hold - Technical'],
      status_ids['On Hold - Customer'],
    ]
    rejection_id    = status_ids['Rejection Pending']
    closed_rej_id   = status_ids['Closed - Rejected']
    build_appr_id   = status_ids['Build Approval']

    TRACKER_IDS.each do |tracker_id|
      role_ids.each do |role_id|
        # Any existing status → any On Hold
        existing_ids.each do |from_id|
          on_hold_ids.each do |to_id|
            WorkflowTransition.find_or_create_by!(
              tracker_id: tracker_id, old_status_id: from_id,
              new_status_id: to_id, role_id: role_id, type: 'WorkflowTransition'
            )
          end
          # On Hold statuses can return to any existing status
          on_hold_ids.each do |from_hold_id|
            WorkflowTransition.find_or_create_by!(
              tracker_id: tracker_id, old_status_id: from_hold_id,
              new_status_id: from_id, role_id: role_id, type: 'WorkflowTransition'
            )
          end
        end

        # Rejection flow: Service Request Review (47) → Rejection Pending → Closed-Rejected
        # Rejection Pending can also reopen to Service Request Review (47)
        [[47, rejection_id], [rejection_id, closed_rej_id],
         [rejection_id, 47]].each do |from_id, to_id|
          WorkflowTransition.find_or_create_by!(
            tracker_id: tracker_id, old_status_id: from_id,
            new_status_id: to_id, role_id: role_id, type: 'WorkflowTransition'
          )
        end

        # Build Approval transitions (Purchase Requisition 50 → Build Approval, Build Approval → next stages)
        [[50, build_appr_id], [build_appr_id, 48], [build_appr_id, 51]].each do |from_id, to_id|
          WorkflowTransition.find_or_create_by!(
            tracker_id: tracker_id, old_status_id: from_id,
            new_status_id: to_id, role_id: role_id, type: 'WorkflowTransition'
          )
        end
      end
    end

    say "Workflow transitions created for #{TRACKER_IDS.length} tracker(s)"
  end

  def down
    NEW_STATUSES.each do |attrs|
      IssueStatus.find_by(name: attrs[:name])&.destroy
    end
  end
end
