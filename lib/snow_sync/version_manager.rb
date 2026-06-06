module SnowSync
  class VersionManager
    def self.auto_assign(issue)
      return unless issue.due_date.present?

      version = find_version_for_date(issue.project_id, issue.due_date)
      return unless version
      return if issue.fixed_version_id == version.id

      issue.update_column(:fixed_version_id, version.id)
      Rails.logger.info "SnowSync VersionManager: issue ##{issue.id} → version '#{version.name}' (due #{issue.due_date})"
    rescue => e
      Rails.logger.error "SnowSync VersionManager: #{e.message}"
    end

    def self.find_version_for_date(project_id, due_date)
      # Find the earliest open version whose effective_date covers the due_date
      Version.where(project_id: project_id, status: 'open')
             .where.not(effective_date: nil)
             .where('effective_date >= ?', due_date)
             .order(:effective_date)
             .first ||
        # Fallback: latest open version with a date (if due_date is already past all versions)
        Version.where(project_id: project_id, status: 'open')
               .where.not(effective_date: nil)
               .order(effective_date: :desc)
               .first
    end
  end
end
