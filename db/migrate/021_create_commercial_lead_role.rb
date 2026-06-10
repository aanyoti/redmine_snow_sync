class CreateCommercialLeadRole < ActiveRecord::Migration[7.2]
  PERMISSIONS = %i[
    view_issues add_issues edit_issues delete_issues copy_issues move_issues
    manage_issue_relations manage_subtasks set_issues_private
    add_issue_notes edit_issue_notes edit_own_issue_notes
    view_private_notes set_notes_private
    add_issue_watchers delete_issue_watchers import_issues
    view_gantt view_calendar view_kanban save_queries
    log_time view_time_entries
  ].freeze

  def up
    role = Role.find_or_initialize_by(name: 'Commercial Lead')
    role.issues_visibility = 'all'
    role.permissions       = PERMISSIONS
    role.save!

    project = Project.find(5)
    [17, 18].each do |user_id|
      user   = User.find_by(id: user_id)
      next unless user
      member = Member.find_or_initialize_by(project: project, user: user)
      member.save! if member.new_record?
      member.roles << role unless member.roles.include?(role)
    end

    puts "Commercial Lead role created (id=#{role.id}), assigned to users 17 and 18."
  end

  def down
    role = Role.find_by(name: 'Commercial Lead')
    return unless role
    MemberRole.where(role: role).destroy_all
    role.destroy
  end
end
