require 'csv'

class SnowExportController < ApplicationController
  before_action :require_login
  before_action :require_authorized

  CF = {
    account:    72,
    order:      55,
    opp_number: 133,
    opp_name:   117,
    mrr_zmw:    83,
    mrr_usd:    85,
    nrr_zmw:    82,
    nrr_usd:    84,
  }.freeze

  def cto_orders
    issues = Issue
      .where(project_id: 5, tracker_id: [14, 18])
      .includes(:status, :tracker, :assigned_to)
      .order(:created_on)

    cf_vals = load_cf_values(issues.map(&:id))
    now     = Time.current

    csv = CSV.generate(headers: true) do |csv|
      csv << %w[Tracker Account Order# Opportunity\ Number Opportunity\ Name
                Status Assignee MRR\ (ZMW) MRR\ (USD) NRR\ (ZMW) NRR\ (USD)
                Age\ (days) Overdue Created\ Date]

      issues.each do |issue|
        cv = cf_vals[issue.id] || {}

        age     = ((now - issue.created_on) / 1.day).floor
        overdue = active_timer_overdue?(issue.id, now)

        csv << [
          issue.tracker.name,
          cv[CF[:account]],
          cv[CF[:order]],
          cv[CF[:opp_number]],
          cv[CF[:opp_name]],
          issue.status.name,
          issue.assigned_to&.name,
          cv[CF[:mrr_zmw]],
          cv[CF[:mrr_usd]],
          cv[CF[:nrr_zmw]],
          cv[CF[:nrr_usd]],
          age,
          overdue ? 'Yes' : 'No',
          issue.created_on.strftime('%Y-%m-%d'),
        ]
      end
    end

    filename = "organic_orders_#{Date.today.strftime('%Y%m%d')}.csv"
    send_data csv, filename: filename, type: 'text/csv', disposition: 'attachment'
  end

  private

  def require_authorized
    allowed = User.current.admin? ||
              User.current.roles.any? { |r| r.name == 'Commercial Lead' } ||
              User.current.groups.any? { |g| [8, 9].include?(g.id) }
    render_403 unless allowed
  end

  def load_cf_values(issue_ids)
    return {} if issue_ids.blank?
    CustomValue
      .where(customized_type: 'Issue', customized_id: issue_ids,
             custom_field_id: CF.values)
      .pluck(:customized_id, :custom_field_id, :value)
      .each_with_object(Hash.new { |h, k| h[k] = {} }) do |(iid, cfid, val), h|
        h[iid][cfid] = val.presence
      end
  end

  def active_timer_overdue?(issue_id, now)
    SnowSlaTimer.where(issue_id: issue_id, exited_at: nil)
                .where('due_at IS NOT NULL AND due_at < ?', now)
                .exists?
  end
end
