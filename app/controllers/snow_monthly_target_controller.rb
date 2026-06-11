class SnowMonthlyTargetController < ApplicationController
  before_action :require_admin_or_tech_lead

  CF_IDS = {
    mrr_zmw: SnowMonthlyTarget::MRR_ZMW_CF_ID,
    nrr_zmw: SnowMonthlyTarget::NRR_ZMW_CF_ID,
    mrr_usd: SnowMonthlyTarget::MRR_USD_CF_ID,
    nrr_usd: SnowMonthlyTarget::NRR_USD_CF_ID
  }.freeze

  def index
    @year  = params[:year].to_i.nonzero?  || Date.today.year
    @month = params[:month].to_i.nonzero? || Date.today.month

    @cf_awip      = IssueCustomField.find_by(name: 'Active WIP')
    @target       = SnowMonthlyTarget.for_month(@year, @month)
    @all_targets  = SnowMonthlyTarget.order(year: :desc, month: :desc).to_a
    @account_cf   = CustomField.find_by(name: 'Account')
    @closed_ids   = IssueStatus.where("name LIKE 'Closed%'").pluck(:id)
    @on_hold_ids  = IssueStatus.where("name LIKE 'On Hold%'").pluck(:id)

    if @cf_awip
      if @target.locked?
        @wip_issues    = Issue.where(id: @target.locked_issue_ids)
                              .includes(:status, :assigned_to).to_a
        @uplift_issues = compute_uplift(@target, @cf_awip)
      else
        @wip_issues    = Issue.where(tracker_id: [14, 18])
                              .joins(:custom_values)
                              .where(custom_values: { custom_field_id: @cf_awip.id, value: '1' })
                              .includes(:status, :assigned_to).to_a
        @uplift_issues = []
      end
      @awip_set_by = awip_set_by_map(@wip_issues + @uplift_issues, @cf_awip)
    else
      @wip_issues = @uplift_issues = []
      @awip_set_by = {}
    end

    @all_issues_count = Issue.where(tracker_id: [14, 18]).count
    @on_hold_count    = Issue.where(tracker_id: [14, 18], status_id: @on_hold_ids).count
  end

  def lock
    year    = params[:year].to_i.nonzero?  || Date.today.year
    month   = params[:month].to_i.nonzero? || Date.today.month
    comment = params[:comment].to_s.strip
    return redirect_err('A reason/comment is required to lock the target.') if comment.blank?

    cf_awip = IssueCustomField.find_by(name: 'Active WIP')
    return redirect_err('Active WIP custom field not found.') unless cf_awip

    target = SnowMonthlyTarget.for_month(year, month)
    return redirect_err("#{target.month_label} target is already locked.") if target.locked?

    active_issues = Issue.where(tracker_id: [14, 18])
                         .joins(:custom_values)
                         .where(custom_values: { custom_field_id: cf_awip.id, value: '1' })
                         .to_a

    target.assign_attributes(
      target_count:   active_issues.size,
      target_mrr_zmw: sum_cf(active_issues, SnowMonthlyTarget::MRR_ZMW_CF_ID),
      target_nrr_zmw: sum_cf(active_issues, SnowMonthlyTarget::NRR_ZMW_CF_ID),
      target_mrr_usd: sum_cf(active_issues, SnowMonthlyTarget::MRR_USD_CF_ID),
      target_nrr_usd: sum_cf(active_issues, SnowMonthlyTarget::NRR_USD_CF_ID),
      locked_at:      Time.current,
      locked_by_id:   User.current.id,
      issue_ids:      active_issues.map(&:id).to_json
    )
    target.save!

    active_issues.each do |issue|
      issue.journals.create!(
        user:  User.current,
        notes: "📌 Included in *#{target.month_label}* Monthly Target by #{User.current.name}.\n\n> #{comment}"
      )
    end

    flash[:notice] = "#{target.month_label} target locked — #{active_issues.size} orders."
    redirect_to snow_monthly_target_path(year: year, month: month)
  end

  def unlock
    year    = params[:year].to_i
    month   = params[:month].to_i
    comment = params[:comment].to_s.strip
    return redirect_err('A reason/comment is required to unlock the target.') if comment.blank?

    target = SnowMonthlyTarget.find_by(year: year, month: month)

    if target&.locked?
      target.locked_issue_ids.each do |issue_id|
        issue = Issue.find_by(id: issue_id)
        next unless issue
        issue.journals.create!(
          user:  User.current,
          notes: "↩ *#{target.month_label}* Monthly Target was unlocked by #{User.current.name}.\n\n> #{comment}"
        )
      end

      target.update!(
        locked_at: nil, locked_by_id: nil, issue_ids: nil,
        target_count: 0,
        target_mrr_zmw: 0, target_nrr_zmw: 0,
        target_mrr_usd: 0, target_nrr_usd: 0
      )
      flash[:notice] = "#{target.month_label} target unlocked."
    end
    redirect_to snow_monthly_target_path(year: year, month: month)
  end

  private

  def require_admin_or_tech_lead
    unless User.current.admin? || tech_lead?
      render_403
    end
  end

  def tech_lead?
    User.current.logged? &&
      User.current.memberships.flat_map(&:roles).any? { |r| r.name == 'Tech Lead' }
  end

  def compute_uplift(target, cf_awip)
    return [] unless target.locked_at.present?
    closed_ids = IssueStatus.where("name LIKE 'Closed%'").pluck(:id)
    month_end  = Date.new(target.year, target.month, 1).end_of_month.end_of_day
    orig_ids   = target.locked_issue_ids

    Issue.where(tracker_id: [14, 18], status_id: closed_ids)
         .joins(:custom_values)
         .where(custom_values: { custom_field_id: cf_awip.id, value: '1' })
         .where.not(id: orig_ids)
         .includes(:status, :assigned_to)
         .to_a
         .select do |i|
           t = SnowSlaTimer.where(issue_id: i.id, status_id: closed_ids).order(:entered_at).last
           t&.entered_at&.between?(target.locked_at, month_end)
         end
  end

  def awip_set_by_map(issues, cf_awip)
    return {} if issues.empty?
    issue_ids = issues.map(&:id)
    details = JournalDetail
      .joins(:journal)
      .where(property: 'cf', prop_key: cf_awip.id.to_s, value: '1',
             journals: { journalized_type: 'Issue', journalized_id: issue_ids })
      .order('journals.created_on ASC')
      .includes(journal: :user)

    result = {}
    details.each do |d|
      iid = d.journal.journalized_id
      result[iid] ||= { user: d.journal.user, at: d.journal.created_on }
    end
    result
  end

  def sum_cf(issues, cf_id)
    issues.sum { |i| i.custom_field_value(cf_id.to_s).to_s.gsub(/[^0-9.]/, '').to_f }.round(2)
  end

  def redirect_err(msg)
    flash[:error] = msg
    redirect_to snow_monthly_target_path
  end
end
