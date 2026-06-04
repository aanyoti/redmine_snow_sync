class AssociateCommercialCfsWithC2 < ActiveRecord::Migration[7.0]
  # CFs shared between Commercial Orders (14) and C2 (18)
  SHARED_CF_IDS = [50, 53, 55, 58, 71, 72, 73, 74, 75, 76, 78, 80, 81, 82, 83, 84, 85, 88].freeze

  def up
    tracker = Tracker.find_by(name: 'C2')
    raise "C2 tracker not found — run migration 009 first" unless tracker

    project = Project.find(5)

    SHARED_CF_IDS.each do |cf_id|
      cf = IssueCustomField.find_by(id: cf_id)
      next unless cf

      cf.trackers << tracker unless cf.trackers.include?(tracker)
      cf.projects << project unless cf.projects.include?(project)
      cf.save!
    end

    # Contractor Name (58) should NOT be on C2 — remove it
    contractor_cf = IssueCustomField.find_by(id: 58)
    if contractor_cf
      contractor_cf.trackers.delete(tracker)
      say "Contractor Name (CF 58) excluded from C2 tracker"
    end

    say "#{SHARED_CF_IDS.length - 1} CFs associated with C2 tracker (58 excluded)"
  end

  def down
    tracker = Tracker.find_by(name: 'C2')
    return unless tracker

    SHARED_CF_IDS.each do |cf_id|
      cf = IssueCustomField.find_by(id: cf_id)
      next unless cf
      cf.trackers.delete(tracker)
    end
  end
end
