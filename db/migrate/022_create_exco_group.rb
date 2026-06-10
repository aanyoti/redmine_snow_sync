class CreateExcoGroup < ActiveRecord::Migration[7.2]
  def up
    # Create EXCO group
    group = Group.find_or_initialize_by(lastname: 'EXCO')
    group.save!

    # Add EXCO to Organic project with KAM role (15)
    project  = Project.find(5)
    kam_role = Role.find(15)
    member   = Member.find_by(project: project, principal: group)
    unless member
      member = Member.new(project: project, principal: group)
      member.roles = [kam_role]
      member.save!
    end

    # Find or create Michael Ketani via LDAP lookup
    user = User.find_by(login: 'Keta611')
    unless user
      user = User.new(
        login:         'Keta611',
        firstname:     'Michael',
        lastname:      'Ketani',
        mail:          'michael.ketani@liquid.tech',
        auth_source_id: 1,
        language:      'en',
        status:        User::STATUS_ACTIVE
      )
      user.save!
    end

    group.users << user unless group.users.include?(user)

    puts "EXCO group created (id=#{group.id}), Michael Ketani added."
  end

  def down
    group = Group.find_by(lastname: 'EXCO')
    return unless group
    MemberRole.joins(:member).where(members: { principal_id: group.id }).destroy_all
    Member.where(principal: group).destroy_all
    group.destroy
  end
end
