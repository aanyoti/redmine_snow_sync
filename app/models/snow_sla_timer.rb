class SnowSlaTimer < ActiveRecord::Base
  belongs_to :issue
  belongs_to :status, class_name: 'IssueStatus'

  # Default SLA targets — overridden by Admin → ServiceNow Sync settings.
  DEFAULT_SLA_DAYS = {
    'Service Request Review'        => 2,
    'Service Scheduling'            => 1,
    'Contractor-Assignment'         => 3,
    'Purchase-Requisition'          => 5,
    'Build Approval'                => 2,
    'Fiber Build'                   => 14,
    'Pending Approval Project'      => 3,
    'Handover Project'              => 3,
    'Requires Sign-off Project'     => 2,
    'C2 - Service Request Review'   => 2,
    'C2 - Technical Assessment'     => 3,
    'C2 - Provisioning'             => 5,
    'C2 - Configuration & Testing'  => 3,
    'C2 - UAT'                      => 2,
    'C2 - Handover'                 => 2,
  }.freeze

  def self.sla_days
    stored = Setting.plugin_redmine_snow_sync['sla_days']
    return DEFAULT_SLA_DAYS if stored.blank?
    DEFAULT_SLA_DAYS.keys.index_with { |k| stored[k].present? ? stored[k].to_i : DEFAULT_SLA_DAYS[k] }
  end

  # Convenience alias used elsewhere in the codebase
  def self.SLA_DAYS
    sla_days
  end

  def self.on_status_change(issue, old_status_id)
    return if issue.tracker_id.nil?

    # Close out the previous status timer
    if old_status_id.present?
      where(issue_id: issue.id, status_id: old_status_id, exited_at: nil)
        .update_all(exited_at: Time.current)
    end

    # Open a new timer for the current status
    status     = issue.status
    sla_days   = self.sla_days[status.name]
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

      # Teams notification
      SnowSync::TeamsNotifier.notify('sla_breach', issue,
        elapsed_days: elapsed,
        target_days:  target
      )

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
    sla_days[issue.status.name]
  end

  # ── MTTI helpers ──────────────────────────────────────────────────────────

  def self.on_hold_ids
    @on_hold_ids ||= IssueStatus.where("name LIKE 'On Hold%'").pluck(:id)
  end

  # Returns timeline array ordered chronologically, grouped by status.
  # Each entry: { status_id, status_name, total_days, visit_count, is_hold, still_open }
  def self.timeline(issue)
    timers = where(issue_id: issue.id).includes(:status).order(:entered_at)
    return [] if timers.empty?

    hold_ids = on_hold_ids
    grouped  = timers.group_by(&:status_id)

    entries = grouped.map do |status_id, ts|
      total_secs = ts.sum { |t| (t.exited_at || Time.current) - t.entered_at }
      {
        status_id:   status_id,
        status_name: ts.first.status.name,
        total_days:  (total_secs / 1.day.to_f).round(2),
        visit_count: ts.count,
        is_hold:     hold_ids.include?(status_id),
        still_open:  ts.any? { |t| t.exited_at.nil? },
        first_entered: ts.map(&:entered_at).min
      }
    end

    entries.sort_by { |e| e[:first_entered] }
  end

  # Total active days for an issue, excluding all On Hold time.
  def self.active_days(issue)
    where(issue_id: issue.id)
      .where.not(status_id: on_hold_ids)
      .sum { |t| ((t.exited_at || Time.current) - t.entered_at) / 1.day.to_f }
  end

  # Mean Time To Install across a collection of issues.
  # Only counts issues that have reached a closed status and have timer data.
  def self.mtti(issues)
    closed_ids = IssueStatus.where("name LIKE 'Closed%'").pluck(:id)
    hold_ids   = on_hold_ids

    completed_times = issues.select { |i| closed_ids.include?(i.status_id) }.filter_map do |issue|
      timers = where(issue_id: issue.id).where.not(status_id: hold_ids)
      next if timers.empty?
      timers.sum { |t| ((t.exited_at || Time.current) - t.entered_at) / 1.day.to_f }
    end.reject { |d| d.zero? }

    return nil if completed_times.empty?
    (completed_times.sum / completed_times.size).round(1)
  end

  # Per-status mean days across a collection of issues (for MTTI breakdown report).
  def self.mtti_by_status(issues)
    hold_ids   = on_hold_ids
    issue_ids  = issues.map(&:id)
    timers     = where(issue_id: issue_ids).where.not(status_id: hold_ids).includes(:status)

    by_status = timers.group_by(&:status_id)
    by_status.filter_map do |status_id, ts|
      days_list = ts.map { |t| ((t.exited_at || Time.current) - t.entered_at) / 1.day.to_f }
      mean = (days_list.sum / days_list.size).round(2)
      { status_name: ts.first.status.name, mean_days: mean, sample_size: days_list.size }
    end.sort_by { |e| -e[:mean_days] }
  end
end
