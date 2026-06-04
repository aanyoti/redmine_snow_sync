class AddOpportunityTypeField < ActiveRecord::Migration[7.0]
  def up
    tracker = Tracker.find_by(id: 14)
    return unless tracker

    cf = IssueCustomField.find_or_create_by!(name: 'Opportunity Type') do |f|
      f.field_format = 'string'
      f.is_required  = false
      f.is_for_all   = false
      f.searchable   = true
    end
    cf.trackers << tracker unless cf.trackers.include?(tracker)
    project = Project.find_by(id: 5)
    cf.projects << project if project && !cf.projects.include?(project)
    cf.save!
  end

  def down
    IssueCustomField.find_by(name: 'Opportunity Type')&.destroy
  end
end
