class SnowDigestMailer < ActionMailer::Base
  REDMINE_URL = 'https://projects-litzm.liquidtelecom.zm'.freeze

  STAGE_ORDER = [
    'Service Request Review', 'Service Scheduling', 'Contractor-Assignment',
    'Site Survey', 'Quote Submission', 'Build Approval',
    'Fiber Build', 'Splicing',
    'Quality Assurance', 'Service Delivery', 'NOC Handover',
    'Customer Handover', 'Billing Notification', 'Submitted',
    'C2 - Service Request Review', 'C2 - Technical Assessment', 'C2 - Provisioning',
    'C2 - Configuration & Testing', 'C2 - UAT', 'C2 - Handover',
    'On Hold - Customer', 'On Hold - Materials', 'On Hold - Technical',
    'Rejection Pending',
  ].freeze

  def status_digest(recipient_email)
    @now      = Time.current
    @rows     = build_rows
    @totals   = build_totals(@rows)
    @workload = build_workload
    @url      = "#{REDMINE_URL}/snow_organic_dashboard"

    mail(
      to:           recipient_email,
from:         Setting.mail_from,
      subject:      "[Organic] Order Status Digest — #{@now.strftime('%d %b %Y %H:%M')}",
      content_type: 'text/html'
    )
  end

  private

  def build_rows
    now        = Time.current
    hold_ids   = IssueStatus.where("name LIKE 'On Hold%'").pluck(:id)
    closed_ids = IssueStatus.where(is_closed: true).pluck(:id)

    issues = Issue
      .where(project_id: 5, tracker_id: [14, 18])
      .where.not(status_id: closed_ids)
      .includes(:status, :tracker, :assigned_to)

    timers = SnowSlaTimer
      .where(issue_id: issues.map(&:id), exited_at: nil)
      .index_by(&:issue_id)

    rows = issues.group_by { |i| [i.tracker.name, i.status.name, hold_ids.include?(i.status_id)] }
      .map do |(tracker, status, on_hold), iss|
        ages        = iss.map { |i| ((now - i.created_on) / 1.day).floor }
        status_ages = iss.filter_map { |i| t = timers[i.id]; t ? ((now - t.entered_at) / 1.day).floor : nil }
        overdue     = iss.count { |i| (t = timers[i.id]) && t.due_at && t.due_at < now }

        assignees = iss.group_by { |i| i.assigned_to&.name || 'Unassigned' }
                       .sort_by { |_, v| -v.size }
                       .first(6)
                       .map { |name, v| "#{name} (#{v.size})" }
                       .join(', ')

        {
          tracker: tracker, status: status, on_hold: on_hold,
          count:           iss.size,
          avg_age:         ages.empty? ? 0 : (ages.sum / ages.size.to_f).round(1),
          max_age:         ages.max || 0,
          avg_status_age:  status_ages.empty? ? 0 : (status_ages.sum / status_ages.size.to_f).round(1),
          max_status_age:  status_ages.max || 0,
          overdue:         overdue,
          assignees:       assignees,
        }
      end

    rows.sort_by { |r| STAGE_ORDER.index(r[:status]) || 999 }
  end

  def build_totals(rows)
    {
      total_open: rows.sum { |r| r[:count] },
      tracker14:  rows.select { |r| r[:tracker] == 'Commercial Orders' }.sum { |r| r[:count] },
      tracker18:  rows.select { |r| r[:tracker] == 'C2' }.sum { |r| r[:count] },
      on_hold:    rows.select { |r| r[:on_hold] }.sum { |r| r[:count] },
      overdue:    rows.sum { |r| r[:overdue] },
    }
  end

  def build_workload
    closed_ids = IssueStatus.where(is_closed: true).pluck(:id)
    issues = Issue
      .where(project_id: 5, tracker_id: [14, 18])
      .where.not(status_id: closed_ids)
      .includes(:assigned_to, :status)

    # Group by assignee, collect counts and current stages
    grouped = issues.group_by { |i| i.assigned_to }
    grouped.map do |user, iss|
      name   = user&.name || 'Unassigned'
      stages = iss.group_by { |i| i.status.name }
                  .sort_by { |s, _| STAGE_ORDER.index(s) || 999 }
                  .map { |s, v| "#{s} (#{v.size})" }
                  .first(3)
                  .join(', ')
      { name: name, count: iss.size, stages: stages }
    end
    .sort_by { |r| -r[:count] }
    .first(15)
  end
end
