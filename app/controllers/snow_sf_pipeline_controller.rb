class SnowSfPipelineController < ApplicationController
  before_action :require_admin_or_commercial_lead

  def index
    conn = ActiveRecord::Base.connection

    @summary = conn.select_one(<<~SQL)
      SELECT
        count(*)                                                        AS total_subscriptions,
        count(DISTINCT order_number)                                    AS total_orders,
        count(DISTINCT account_name)                                    AS total_accounts,
        count(DISTINCT CASE WHEN is_new_logo THEN account_name END)    AS new_logo_accounts,
        count(DISTINCT CASE WHEN is_new_logo THEN order_number END)    AS new_logo_orders,
        coalesce(sum(mrr_zmw), 0)::bigint                              AS total_mrr_zmw,
        coalesce(sum(nrr_zmw), 0)::bigint                              AS total_nrr_zmw,
        coalesce(sum(CASE WHEN is_new_logo THEN mrr_zmw ELSE 0 END), 0)::bigint AS new_logo_mrr_zmw,
        count(CASE WHEN sf_status = 'Service Delivered' THEN 1 END)    AS delivered_count,
        count(CASE WHEN sf_status = 'Accepted by Service Delivery' THEN 1 END) AS accepted_count,
        count(CASE WHEN sf_status = 'Rejected by Service Delivery' THEN 1 END) AS rejected_count
      FROM vw_sf_pipeline
      WHERE is_fy27
    SQL

    @monthly = conn.select_all("SELECT * FROM vw_sf_monthly ORDER BY month_year").to_a

    # Build pipeline query with filters
    conditions = ["is_fy27"]
    conditions << "is_new_logo = true"                                           if params[:new_logo] == '1'
    conditions << conn.sanitize_sql_array(["account_owner = ?", params[:kam]])   if params[:kam].present?
    conditions << conn.sanitize_sql_array(["sf_status = ?", params[:status]])    if params[:status].present?
    conditions << conn.sanitize_sql_array(["opportunity_type = ?", params[:opp_type]]) if params[:opp_type].present?

    where = "WHERE #{conditions.join(' AND ')}"

    @orders = conn.select_all(<<~SQL).to_a
      SELECT id, order_number, account_name, opportunity_type, subscription_name,
             sf_status, account_owner, currency, mrr_amount, nrr_amount, mrr_zmw, nrr_zmw,
             is_new_logo, in_organic, is_delivered, created_date, snow_request_number
      FROM vw_sf_pipeline
      #{where}
      ORDER BY created_date DESC NULLS LAST
      LIMIT 300
    SQL

    @kams      = conn.select_rows("SELECT DISTINCT account_owner FROM vw_sf_pipeline WHERE is_fy27 AND account_owner IS NOT NULL ORDER BY account_owner").flatten
    @statuses  = conn.select_rows("SELECT DISTINCT sf_status FROM vw_sf_pipeline WHERE is_fy27 AND sf_status IS NOT NULL ORDER BY sf_status").flatten
    @opp_types = conn.select_rows("SELECT DISTINCT opportunity_type FROM vw_sf_pipeline WHERE is_fy27 AND opportunity_type IS NOT NULL ORDER BY opportunity_type").flatten
  end

  private

  def require_admin_or_commercial_lead
    commercial_lead_role_id = 23
    return if User.current.admin?
    return if User.current.memberships.flat_map(&:role_ids).include?(commercial_lead_role_id)
    deny_access
  end
end
