class AddUsdCustomFields < ActiveRecord::Migration[7.2]
  FIELDS = [
    { name: 'NRR (USD)', field_format: 'string' },
    { name: 'MRR (USD)', field_format: 'string' }
  ].freeze

  def up
    tracker = Tracker.find_by(name: 'Fiber Orders')
    project = Project.find(5)

    FIELDS.each do |attrs|
      next if IssueCustomField.exists?(name: attrs[:name])

      cf = IssueCustomField.create!(
        name:         attrs[:name],
        field_format: attrs[:field_format],
        is_for_all:   false,
        is_filter:    true,
        searchable:   true
      )
      cf.trackers << tracker if tracker && !cf.trackers.include?(tracker)
      cf.projects << project if project && !cf.projects.include?(project)
    end
  end

  def down
    FIELDS.each { |a| IssueCustomField.find_by(name: a[:name])&.destroy }
  end
end
