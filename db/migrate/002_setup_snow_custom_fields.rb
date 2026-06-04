class SetupSnowCustomFields < ActiveRecord::Migration[7.0]
  # Fields to create — due_date/subject/description are native Redmine fields.
  # Order Number (ID 55) already exists on this tracker, so we skip it.
  NEW_FIELDS = [
    { name: 'SNow Request #',         field_format: 'string' },
    { name: 'Account',                field_format: 'string' },
    { name: 'Requested For',          field_format: 'string' },
    { name: 'Service',                field_format: 'string' },
    { name: 'SNow Opened',            field_format: 'date'   },
    { name: 'Assignment Group',       field_format: 'string' },
    { name: 'Request State',          field_format: 'string' },
    { name: 'Service Delivery Stage', field_format: 'string' },
    { name: 'SNow Sys ID',            field_format: 'string' },
  ].freeze

  def up
    # 1. Rename tracker
    Tracker.find_by(name: 'Project Task')&.update_columns(name: 'Fiber Orders')

    tracker = Tracker.find_by(name: 'Fiber Orders')
    project = Project.find_by(name: 'Organic')

    # 2. Create new custom fields and associate with tracker + project
    NEW_FIELDS.each do |attrs|
      next if IssueCustomField.exists?(name: attrs[:name])

      cf = IssueCustomField.create!(
        name:         attrs[:name],
        field_format: attrs[:field_format],
        is_required:  false,
        is_for_all:   false,
        is_filter:    true,
        searchable:   true
      )
      cf.trackers << tracker if tracker && !cf.trackers.include?(tracker)
      cf.projects << project if project && !cf.projects.include?(project)
    end

    # 3. Ensure existing fields are also visible on Organic project + Fiber Orders tracker
    [55, 57].each do |cf_id|
      cf = IssueCustomField.find_by(id: cf_id)
      next unless cf
      cf.trackers << tracker if tracker && !cf.trackers.include?(tracker)
      cf.projects << project if project && !cf.projects.include?(project)
    end
  end

  def down
    NEW_FIELDS.each { |attrs| IssueCustomField.find_by(name: attrs[:name])&.destroy }
    Tracker.find_by(name: 'Fiber Orders')&.update_columns(name: 'Project Task')
  end
end
