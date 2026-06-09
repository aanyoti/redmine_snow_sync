class ConfigureRolesAndAccess < ActiveRecord::Migration[7.2]
  # ── Role IDs ──────────────────────────────────────────────────────────────
  SD_ROLE_ID      = 9
  PROJECTS_ROLE_ID = 7
  KAM_ROLE_ID     = 15
  CONTRACTOR_ROLE_ID = 20

  # ── Group / Project IDs ───────────────────────────────────────────────────
  SD_GROUP_ID     = 8
  ORGANIC_ID      = 5

  # ── CF visibility buckets ─────────────────────────────────────────────────
  # visible: true  → everyone (including contractors)
  VISIBLE_ALL = [
    55,            # Order Number
    58,            # Contractor Name
    72,            # Account (customer name)
    89,            # Service Type
    91, 92, 93,    # Fiber Length, Media Converters, P2P Radios
    94, 95, 96,    # Routers, Switches, APs
    98, 99, 100,   # A-End Termination POP, Switch/Router, Port
    101, 102, 103, # B-End Termination POP, Switch/Router, Port
    104, 105,      # VLAN/IP, Bandwidth Capacity
  ].freeze

  # visible: false, roles: SD + Projects + KAM  (contractors cannot see)
  VISIBLE_SD_PROJ_KAM = [
    71,            # SNow Request #
    73,            # Requested For
    74,            # Service
    78,            # Service Delivery Stage
    82, 83,        # NRR/MRR ZMW
    84, 85,        # NRR/MRR USD
    90,            # Services
  ].freeze

  # visible: false, roles: SD + Projects only
  VISIBLE_SD_PROJ_ONLY = [
    50,            # Predecessor Issue
    53,            # Rejection Reason
    75,            # SNow Opened
    76,            # Assignment Group
    80,            # Account Number
    81,            # Prepared By
    88,            # Opportunity Type
    97,            # Active WIP
  ].freeze

  def up
    configure_contractor_role
    configure_kam_role
    add_sd_to_organic
    apply_cf_visibility
  end

  def down
    # Non-destructive — permissions and visibility changes are reversible via admin UI
  end

  private

  # ── Contractor role: own issues, edit + notes only ────────────────────────
  def configure_contractor_role
    role = Role.find_by(id: CONTRACTOR_ROLE_ID)
    return unless role

    role.issues_visibility = 'own'
    role.permissions = %i[
      view_issues
      edit_issues
      add_issue_notes
      edit_own_issue_notes
    ]
    role.save!
    puts "  Contractor role updated (issues_visibility: own, edit_issues + add_issue_notes)"
  end

  # ── KAM role: view + add notes, no editing ────────────────────────────────
  def configure_kam_role
    role = Role.find_by(id: KAM_ROLE_ID)
    return unless role

    role.issues_visibility = 'all'
    role.permissions = %i[
      view_issues
      add_issue_notes
      edit_own_issue_notes
      view_kanban
      save_queries
      view_gantt
      view_calendar
    ]
    role.save!
    puts "  KAM role updated (issues_visibility: all, view + add_issue_notes)"
  end

  # ── Add Service Delivery group to Organic project ─────────────────────────
  def add_sd_to_organic
    project = Project.find_by(id: ORGANIC_ID)
    group   = Group.find_by(id: SD_GROUP_ID)
    role    = Role.find_by(id: SD_ROLE_ID)
    return unless project && group && role

    member = Member.find_by(project_id: project.id, user_id: group.id)
    if member
      member.role_ids = (member.role_ids | [role.id])
      member.save!
      puts "  Service Delivery group already in Organic — ensured role"
    else
      member = Member.new(project_id: project.id, user_id: group.id)
      member.role_ids = [role.id]
      member.save!
      puts "  Service Delivery group added to Organic with Service Delivery role"
    end
  end

  # ── Custom field visibility ───────────────────────────────────────────────
  def apply_cf_visibility
    sd_proj_kam_roles = Role.where(id: [SD_ROLE_ID, PROJECTS_ROLE_ID, KAM_ROLE_ID]).to_a
    sd_proj_roles     = Role.where(id: [SD_ROLE_ID, PROJECTS_ROLE_ID]).to_a

    VISIBLE_ALL.each do |cf_id|
      cf = IssueCustomField.find_by(id: cf_id)
      next unless cf
      cf.update!(visible: true)
      cf.roles = []
    end

    VISIBLE_SD_PROJ_KAM.each do |cf_id|
      cf = IssueCustomField.find_by(id: cf_id)
      next unless cf
      cf.roles = sd_proj_kam_roles
      cf.update!(visible: false)
    end

    VISIBLE_SD_PROJ_ONLY.each do |cf_id|
      cf = IssueCustomField.find_by(id: cf_id)
      next unless cf
      cf.roles = sd_proj_roles
      cf.update!(visible: false)
    end

    puts "  CF visibility applied (#{VISIBLE_ALL.size} open, #{VISIBLE_SD_PROJ_KAM.size} SD/Proj/KAM, #{VISIBLE_SD_PROJ_ONLY.size} SD/Proj only)"
  end
end
