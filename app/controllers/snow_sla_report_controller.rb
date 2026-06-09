class SnowSlaReportController < ApplicationController
  before_action :require_admin

  def index
    scope = SnowSlaTimer.joins(:issue, :status)
                        .where(issues: { tracker_id: [14, 18] })

    @filter_result  = params[:result]
    @filter_open    = params[:open]
    @filter_tracker = params[:tracker_id].presence

    if @filter_result == 'breached'
      scope = scope.where(breached: true)
    elsif @filter_result == 'on_track'
      scope = scope.where(breached: false).where('snow_sla_timers.due_at IS NULL OR snow_sla_timers.due_at >= ?', Time.current)
    elsif @filter_result == 'no_target'
      scope = scope.where(due_at: nil)
    end

    scope = scope.where(exited_at: nil)             if @filter_open == '1'
    scope = scope.where(issues: { tracker_id: @filter_tracker.to_i }) if @filter_tracker

    @limit       = 50
    @timer_count = scope.count
    @timer_pages = Redmine::Pagination::Paginator.new(@timer_count, @limit, params[:page])
    @timers      = scope.includes(:status, :issue)
                        .order('snow_sla_timers.entered_at DESC')
                        .limit(@limit)
                        .offset(@timer_pages.offset)

    @account_cf_id = CustomField.find_by(name: 'Account')&.id&.to_s

    # MTTI — all tracker 14/18 issues (unfiltered, for overall stats)
    all_issues      = Issue.where(tracker_id: [14, 18]).to_a
    @mtti_target    = (Setting.plugin_redmine_snow_sync['mtti_target'].presence || 15).to_i
    @mtti           = SnowSlaTimer.mtti(all_issues)
    @mtti_breakdown = SnowSlaTimer.mtti_by_status(all_issues)
    @monthly_mtti   = SnowSlaTimer.monthly_summary(all_issues)

    @summary = {
      total:     SnowSlaTimer.joins(:issue).where(exited_at: nil, issues: { tracker_id: [14, 18] }).count,
      breached:  SnowSlaTimer.joins(:issue).where(exited_at: nil, breached: true,  issues: { tracker_id: [14, 18] }).count,
      due_today: SnowSlaTimer.joins(:issue)
                             .where(exited_at: nil, breached: false, issues: { tracker_id: [14, 18] })
                             .where('due_at BETWEEN ? AND ?', Time.current.beginning_of_day, Time.current.end_of_day)
                             .count,
      on_track:  SnowSlaTimer.joins(:issue)
                             .where(exited_at: nil, breached: false, issues: { tracker_id: [14, 18] })
                             .where('due_at IS NULL OR due_at > ?', Time.current.end_of_day)
                             .count
    }
  end
end
