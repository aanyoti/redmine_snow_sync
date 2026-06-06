class CreateMaterialCustomFields < ActiveRecord::Migration[7.2]
  MATERIAL_CFS = ['Fiber Length', 'Media Converters', 'P2P Radios', 'Routers', 'Switches', 'APs'].freeze
  TRACKER_ID   = 14  # Commercial Orders

  def up
    MATERIAL_CFS.each do |name|
      next if execute("SELECT id FROM custom_fields WHERE type='IssueCustomField' AND name='#{name}'").ntuples > 0

      execute <<~SQL
        INSERT INTO custom_fields
          (type, name, field_format, is_required, is_for_all, is_filter,
           searchable, editable, visible, multiple, default_value)
        VALUES
          ('IssueCustomField', '#{name}', 'int', false, false, true,
           false, true, true, false, '')
      SQL
    end

    # Associate all 6 with Commercial Orders tracker
    execute <<~SQL
      INSERT INTO custom_fields_trackers (custom_field_id, tracker_id)
      SELECT cf.id, #{TRACKER_ID}
      FROM custom_fields cf
      WHERE cf.type = 'IssueCustomField'
        AND cf.name IN (#{MATERIAL_CFS.map { |n| "'#{n}'" }.join(',')})
        AND NOT EXISTS (
          SELECT 1 FROM custom_fields_trackers x
          WHERE x.custom_field_id = cf.id AND x.tracker_id = #{TRACKER_ID}
        )
    SQL
  end

  def down
    execute <<~SQL
      DELETE FROM custom_fields_trackers
      WHERE custom_field_id IN (
        SELECT id FROM custom_fields
        WHERE type='IssueCustomField' AND name IN (#{MATERIAL_CFS.map { |n| "'#{n}'" }.join(',')})
      )
    SQL
    execute <<~SQL
      DELETE FROM custom_fields
      WHERE type='IssueCustomField'
        AND name IN (#{MATERIAL_CFS.map { |n| "'#{n}'" }.join(',')})
    SQL
  end
end
