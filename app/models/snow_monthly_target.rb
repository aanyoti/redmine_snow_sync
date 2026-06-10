class SnowMonthlyTarget < ActiveRecord::Base
  belongs_to :locked_by, class_name: 'User', optional: true

  MRR_ZMW_CF_ID = 83
  NRR_ZMW_CF_ID = 82
  MRR_USD_CF_ID = 85
  NRR_USD_CF_ID = 84

  def self.for_month(year, month)
    find_or_initialize_by(year: year, month: month)
  end

  def locked?
    locked_at.present?
  end

  def locked_issue_ids
    return [] if issue_ids.blank?
    JSON.parse(issue_ids)
  rescue JSON::ParserError
    []
  end

  def month_label
    "#{Date::MONTHNAMES[month]} #{year}"
  end

  # Live delivery + uplift stats for this locked target.
  def stats
    closed_status_ids = IssueStatus.where("name LIKE 'Closed%'").pluck(:id)
    orig_ids          = locked_issue_ids
    orig_issues       = orig_ids.any? ? Issue.where(id: orig_ids).to_a : []

    delivered = orig_issues.select { |i| closed_status_ids.include?(i.status_id) }

    uplift_issues = compute_uplift(closed_status_ids, orig_ids)

    {
      delivered_count:   delivered.size,
      achieved_pct:      target_count > 0 ? (delivered.size.to_f / target_count * 100).round(1) : nil,
      delivered_mrr_zmw: sum_cf(delivered,     MRR_ZMW_CF_ID),
      delivered_nrr_zmw: sum_cf(delivered,     NRR_ZMW_CF_ID),
      delivered_mrr_usd: sum_cf(delivered,     MRR_USD_CF_ID),
      delivered_nrr_usd: sum_cf(delivered,     NRR_USD_CF_ID),
      uplift_count:      uplift_issues.size,
      uplift_mrr_zmw:    sum_cf(uplift_issues, MRR_ZMW_CF_ID),
      uplift_nrr_zmw:    sum_cf(uplift_issues, NRR_ZMW_CF_ID),
      uplift_mrr_usd:    sum_cf(uplift_issues, MRR_USD_CF_ID),
      uplift_nrr_usd:    sum_cf(uplift_issues, NRR_USD_CF_ID)
    }
  end

  private

  def compute_uplift(closed_status_ids, orig_ids)
    return [] unless locked_at.present?

    cf_awip = IssueCustomField.find_by(name: 'Active WIP')
    return [] unless cf_awip

    month_end = Date.new(year, month, 1).end_of_month.end_of_day

    Issue.where(tracker_id: [14, 18], status_id: closed_status_ids)
         .joins(:custom_values)
         .where(custom_values: { custom_field_id: cf_awip.id, value: '1' })
         .where.not(id: orig_ids)
         .to_a
         .select do |i|
           timer = SnowSlaTimer.where(issue_id: i.id, status_id: closed_status_ids)
                               .order(:entered_at).last
           timer&.entered_at&.between?(locked_at, month_end)
         end
  end

  def sum_cf(issues, cf_id)
    issues.sum { |i| i.custom_field_value(cf_id.to_s).to_s.gsub(/[^0-9.]/, '').to_f }.round(2)
  end
end
