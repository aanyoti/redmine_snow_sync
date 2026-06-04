module SnowSync
  module KamGroupManager
    GROUP_NAME  = 'KAMs'.freeze
    ROLE_NAME   = 'Key Account Manager'.freeze

    def self.ensure_member(user)
      return unless user.is_a?(User)

      group   = find_or_create_group
      project = Project.find(5)

      ensure_project_membership(group, project)
      add_user_to_group(group, user)
    end

    def self.find_or_create_group
      Group.find_by(lastname: GROUP_NAME) ||
        Group.create!(lastname: GROUP_NAME)
    end

    def self.ensure_project_membership(group, project)
      return if Member.exists?(project: project, user_id: group.id)

      role = Role.find_by(name: ROLE_NAME)
      return Rails.logger.warn("SnowSync: role '#{ROLE_NAME}' not found") unless role

      member = Member.new(project: project, principal: group)
      member.role_ids = [role.id]
      member.save!
      Rails.logger.info "SnowSync: added KAMs group to project #{project.id} with role '#{ROLE_NAME}'"
    end

    def self.add_user_to_group(group, user)
      return if group.users.include?(user)

      group.users << user
      Rails.logger.info "SnowSync: added #{user.login} to KAMs group"
    end
  end
end
