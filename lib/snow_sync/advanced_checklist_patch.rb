module SnowSync
  module AdvancedChecklistPatch
    # When a checklist is created from a template, assign each item to:
    #   - the user explicitly assigned in the template (e.g. Musonda on Build Approval), OR
    #   - the issue's current assignee (contractor, PM, etc.) if no template assignee is set
    def copy_items_from_template(template)
      default_assignee = issue&.assigned_to

      ActiveRecord::Base.transaction do
        template.items.each do |question|
          items.create(
            title:       question.title,
            created_by:  User.current,
            sort_order:  question.sort_order,
            assigned_to: question.assigned_to || default_assignee,
            due_date:    question.deadline.nil? ? nil : DateTime.now.next_day(question.deadline)
          )
        end
      end
    end
  end
end
