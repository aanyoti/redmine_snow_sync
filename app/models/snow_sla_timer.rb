class SnowSlaTimer < ActiveRecord::Base
  belongs_to :issue
  belongs_to :status, class_name: 'IssueStatus'

  # SLA targets in calendar days per status name.
  # Times for remaining statuses will be added once full workflow is confirmed.
  SLA_DAYS = {
    'Service Request Review' => 2,
    'Service Scheduling'     => 1,
  }.freeze

  def self.on_status_change(issue, old_status_id)
    return if issue.tracker_id.nil?

    # Close out the previous status timer
    if old_status_id.present?
      where(issue_id: issue.id, status_id: old_status_id, exited_at: nil)
        .update_all(exited_at: Time.current)
    end

    # Open a new timer for the current status
    status     = issue.status
    sla_days   = SLA_DAYS[status.name]
    due_at     = sla_days ? sla_days.days.from_now : nil

    create!(
      issue_id:   issue.id,
      status_id:  issue.status_id,
      entered_at: Time.current,
      due_at:     due_at,
      breached:   false
    )
  end

  def self.check_breaches
    now = Time.current
    overdue = where(exited_at: nil, breached: false)
                .where('due_at IS NOT NULL AND due_at < ?', now)

    overdue.find_each do |timer|
      issue  = Issue.find_by(id: timer.issue_id)
      next unless issue

      elapsed = ((now - timer.entered_at) / 1.day).round(1)
      target  = ((timer.due_at - timer.entered_at) / 1.day).round(1)

      # Add journal note
      user    = User.where(admin: true).first
      journal = issue.journals.build(user: user)
      journal.notes = "⚠ SLA breach: issue has been in *#{issue.status.name}* for #{elapsed} day(s) (target: #{target} day(s))."
      journal.save

      # Email notification to assignee + watchers
      recipients = ([issue.assigned_to] + issue.watchers.map(&:user)).compact.uniq.select(&:active?)
      recipients.each do |recipient|
        SnowSlaMailer.breach_notification(recipient, issue, issue.status.name, elapsed, target).deliver_now rescue nil
      end

      timer.update!(breached: true, notified_at: now)
      Rails.logger.warn "SnowSLA: breach on issue ##{issue.id} in status '#{issue.status.name}' (#{elapsed}d / #{target}d)"
    end
  end

  def self.elapsed_days(issue)
    timer = where(issue_id: issue.id, status_id: issue.status_id, exited_at: nil).order(:entered_at).last
    return nil unless timer
    ((Time.current - timer.entered_at) / 1.day).round(1)
  end

  def self.target_days(issue)
    SLA_DAYS[issue.status.name]
  end
end
