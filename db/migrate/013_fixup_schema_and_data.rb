class FixupSchemaAndData < ActiveRecord::Migration[7.2]
  def up
    # 1. Hide estimated_hours from Commercial Orders and C2 tracker forms
    #    CORE_FIELDS index: assigned_to=0, category=1, fixed_version=2, parent=3,
    #                       start_date=4, due_date=5, estimated_hours=6, done_ratio=7,
    #                       description=8, priority=9
    #    Bit 6 (64) = estimated_hours disabled
    execute "UPDATE trackers SET fields_bits = (fields_bits | 64) WHERE id IN (14, 18)"

    # 2. Make Service Type (CF 89) filterable so it appears in Group By
    execute "UPDATE custom_fields SET is_filter = true WHERE id = 89"

    # 3. Backfill Opportunity Type (CF 88) = Service Type (CF 89) for existing C2 issues
    #    Update rows that already exist but are blank
    execute <<~SQL
      UPDATE custom_values cv88
      SET value = cv89.value
      FROM custom_values cv89
      JOIN issues i ON i.id = cv89.customized_id AND i.tracker_id = 18
      WHERE cv89.customized_type = 'Issue'
        AND cv89.custom_field_id = 89
        AND cv89.value <> ''
        AND cv88.customized_type = 'Issue'
        AND cv88.customized_id = cv89.customized_id
        AND cv88.custom_field_id = 88
        AND (cv88.value IS NULL OR cv88.value = '')
    SQL
    #    Insert rows for C2 issues that have no CF 88 record yet
    execute <<~SQL
      INSERT INTO custom_values (customized_type, customized_id, custom_field_id, value)
      SELECT 'Issue', i.id, 88, cv89.value
      FROM issues i
      JOIN custom_values cv89 ON cv89.customized_type = 'Issue'
        AND cv89.customized_id = i.id AND cv89.custom_field_id = 89
      WHERE i.tracker_id = 18
        AND cv89.value <> ''
        AND NOT EXISTS (
          SELECT 1 FROM custom_values x
          WHERE x.customized_type = 'Issue'
            AND x.customized_id = i.id
            AND x.custom_field_id = 88
        )
    SQL

    # 4. Backfill category (Segment - Enterprise) for 4 C2 issues with no category
    execute <<~SQL
      UPDATE issues SET category_id = (
        SELECT id FROM issue_categories
        WHERE project_id = issues.project_id AND name = 'Segment - Enterprise'
        LIMIT 1
      )
      WHERE tracker_id = 18
        AND category_id IS NULL
    SQL
  end

  def down
    execute "UPDATE trackers SET fields_bits = (fields_bits & ~64) WHERE id IN (14, 18)"
    execute "UPDATE custom_fields SET is_filter = false WHERE id = 89"
  end
end
