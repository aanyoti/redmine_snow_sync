class BuildApprovalWorkflowAndChecklists < ActiveRecord::Migration[7.2]
  TRACKER_ID  = 14  # Commercial Orders
  PROJECT_ID  = 5   # Organic
  ADMIN_ID    = 1
  MUSONDA_ID  = 17

  # status IDs
  PR_STATUS       = 50  # Purchase-Requisition
  BUILD_APPROVAL  = 90
  FIBER_BUILD     = 51
  CONTRACTOR_ASGN = 49
  HANDOVER        = 59

  def up
    # ── 1. Table to store contractor before handing off to Musonda ────────────
    create_table :snow_build_approval_contractors do |t|
      t.integer :issue_id,      null: false
      t.integer :contractor_id, null: false
      t.timestamps
    end
    add_index :snow_build_approval_contractors, :issue_id, unique: true

    # ── 2. Add Build Approval → Purchase-Requisition workflow transition ───────
    # (one row per role — add for all non-builtin roles)
    execute <<~SQL
      INSERT INTO workflows (tracker_id, old_status_id, new_status_id, role_id, type)
      SELECT #{TRACKER_ID}, #{BUILD_APPROVAL}, #{PR_STATUS}, r.id, 'WorkflowTransition'
      FROM roles r
      WHERE r.builtin = 0
        AND NOT EXISTS (
          SELECT 1 FROM workflows w2
          WHERE w2.tracker_id   = #{TRACKER_ID}
            AND w2.old_status_id = #{BUILD_APPROVAL}
            AND w2.new_status_id = #{PR_STATUS}
            AND w2.role_id       = r.id
        )
    SQL

    # ── 3. Checklist templates + items + workflow triggers ────────────────────
    templates = [
      {
        status_id: CONTRACTOR_ASGN,
        title:     'Site Survey Checklist',
        items: [
          'Site access arranged and confirmed with customer',
          'Existing infrastructure and cabling documented',
          'Fibre routing path identified and measured',
          'Power supply verified at termination/comms room',
          'Customer rack space and comms room confirmed',
          'Hazards and obstructions noted',
          'All measurements recorded (fibre length, equipment locations)',
          'Minimum 5 site photos taken and ready to upload',
        ]
      },
      {
        status_id: BUILD_APPROVAL,
        title:     'Build Approval Review',
        items: [
          'Minimum 5 site photos reviewed and acceptable',
          'Contractor quote received and attached (PDF)',
          'Quoted fibre length matches survey measurement',
          'Equipment quantities match site survey (routers, switches, APs, media converters, P2P radios)',
          'Bill of quantities approved',
          'Budget within approved limits',
          'Customer approval for installation route confirmed',
        ]
      },
      {
        status_id: FIBER_BUILD,
        title:     'Fibre Build Checklist',
        items: [
          'All materials delivered to site and verified against BOQ',
          'Fibre cable installed and spliced',
          'Cable management / conduit installed',
          'Equipment mounted and powered on',
          'All cables and ports labeled correctly',
          'Fibre test results documented and attached',
          'Site cleaned up after installation',
        ]
      },
      {
        status_id: HANDOVER,
        title:     'Service Handover Checklist',
        items: [
          'Service connectivity tested end-to-end',
          'Speed / performance meets contracted SLA',
          'Customer walkthrough completed',
          'Customer acceptance form signed and attached',
          'Support contact numbers and escalation path provided',
          'As-built drawings attached',
          'Handover document signed by customer and Liquid representative',
        ]
      }
    ]

    templates.each_with_index do |tpl, _idx|
      now = Time.current.strftime('%Y-%m-%d %H:%M:%S')

      # Insert template
      execute <<~SQL
        INSERT INTO advanced_checklist_templates
          (title, created_at, updated_at, deleted, sort_order, created_by_id,
           list_type, published, tracker_id, is_public)
        VALUES
          ('#{tpl[:title]}', '#{now}', '#{now}', false, 0, #{ADMIN_ID},
           'Usual', true, #{TRACKER_ID}, true)
      SQL

      template_id = execute("SELECT id FROM advanced_checklist_templates WHERE title='#{tpl[:title]}' AND tracker_id=#{TRACKER_ID} ORDER BY id DESC LIMIT 1").first['id']

      # Link template to project
      execute <<~SQL
        INSERT INTO advanced_checklist_templates_projects (project_id, checklist_template_id)
        VALUES (#{PROJECT_ID}, #{template_id})
      SQL

      # Link template to status (auto-apply trigger)
      execute <<~SQL
        INSERT INTO advanced_checklist_workflows (template_id, status_id)
        VALUES (#{template_id}, #{tpl[:status_id]})
      SQL

      # Insert items
      tpl[:items].each_with_index do |item_title, sort|
        assigned = tpl[:status_id] == BUILD_APPROVAL ? MUSONDA_ID : 'NULL'
        execute <<~SQL
          INSERT INTO advanced_checklist_template_items
            (title, created_at, updated_at, deleted, sort_order, created_by_id, template_id, assigned_to_id)
          VALUES
            ('#{item_title.gsub("'", "''")}', '#{now}', '#{now}', false, #{sort}, #{ADMIN_ID}, #{template_id}, #{assigned})
        SQL
      end
    end
  end

  def down
    drop_table :snow_build_approval_contractors

    execute <<~SQL
      DELETE FROM workflows
      WHERE tracker_id=#{TRACKER_ID} AND old_status_id=#{BUILD_APPROVAL} AND new_status_id=#{PR_STATUS}
    SQL

    %w[Site\ Survey\ Checklist Build\ Approval\ Review Fibre\ Build\ Checklist Service\ Handover\ Checklist].each do |title|
      execute <<~SQL
        DELETE FROM advanced_checklist_template_items
        WHERE template_id IN (SELECT id FROM advanced_checklist_templates WHERE title='#{title}')
      SQL
      execute <<~SQL
        DELETE FROM advanced_checklist_workflows
        WHERE template_id IN (SELECT id FROM advanced_checklist_templates WHERE title='#{title}')
      SQL
      execute <<~SQL
        DELETE FROM advanced_checklist_templates_projects
        WHERE checklist_template_id IN (SELECT id FROM advanced_checklist_templates WHERE title='#{title}')
      SQL
      execute "DELETE FROM advanced_checklist_templates WHERE title='#{title}'"
    end
  end
end
