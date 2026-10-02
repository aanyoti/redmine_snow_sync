class SnowOrganicDashboardController < ApplicationController
  before_action :require_login
  layout false

  def index
    conn = ActiveRecord::Base.connection
    @usd_rate = Setting.plugin_redmine_snow_sync['zmw_usd_rate'].to_f
    @usd_rate = 18.0 if @usd_rate <= 0

    # ── SF Summary KPIs ──────────────────────────────────────────────────────
    @sf_summary = conn.select_one(<<~SQL)
      SELECT
        count(*)                                                           AS total_subscriptions,
        count(DISTINCT order_number)                                       AS total_orders,
        count(DISTINCT account_name)                                       AS total_accounts,
        count(DISTINCT CASE WHEN is_new_logo THEN account_name END)       AS new_logo_accounts,
        count(DISTINCT CASE WHEN is_new_logo THEN order_number END)       AS new_logo_orders,
        coalesce(sum(mrr_zmw),0)::bigint                                   AS total_mrr_zmw,
        coalesce(sum(nrr_zmw),0)::bigint                                   AS total_nrr_zmw,
        coalesce(sum(CASE WHEN is_new_logo THEN mrr_zmw ELSE 0 END),0)::bigint AS new_logo_mrr_zmw,
        count(CASE WHEN sf_status='Service Delivered' THEN 1 END)         AS delivered_count,
        count(CASE WHEN sf_status='Accepted by Service Delivery' THEN 1 END) AS accepted_count,
        count(CASE WHEN sf_status='Rejected by Service Delivery' THEN 1 END) AS rejected_count,
        count(CASE WHEN sf_status='Sent for Service Qualification' THEN 1 END) AS in_qual_count,
        count(CASE WHEN sf_status='Service Delivery is not required' THEN 1 END) AS not_required_count,
        coalesce(sum(CASE WHEN sf_status='Accepted by Service Delivery' THEN mrr_zmw ELSE 0 END),0)::bigint AS accepted_mrr,
        coalesce(sum(CASE WHEN sf_status='Sent for Service Qualification' THEN mrr_zmw ELSE 0 END),0)::bigint AS qual_mrr,
        coalesce(sum(CASE WHEN sf_status='Service Delivered' THEN mrr_zmw ELSE 0 END),0)::bigint AS delivered_mrr,
        coalesce(sum(CASE WHEN sf_status='Rejected by Service Delivery' THEN mrr_zmw ELSE 0 END),0)::bigint AS rejected_mrr
      FROM vw_sf_pipeline WHERE is_fy27
    SQL

    # ── SF Monthly ───────────────────────────────────────────────────────────
    @sf_monthly = conn.select_all("SELECT * FROM vw_sf_monthly ORDER BY period_start").to_a

    # ── SF Status breakdown ──────────────────────────────────────────────────
    @sf_statuses = conn.select_all(<<~SQL).to_a
      SELECT sf_status, count(*) AS cnt, coalesce(sum(mrr_zmw),0)::bigint AS mrr
      FROM vw_sf_pipeline WHERE is_fy27 AND sf_status IS NOT NULL
      GROUP BY sf_status ORDER BY cnt DESC
    SQL

    # ── SF Opportunity types ─────────────────────────────────────────────────
    @sf_opp_types = conn.select_all(<<~SQL).to_a
      SELECT opportunity_type, count(*) AS cnt
      FROM vw_sf_pipeline WHERE is_fy27 AND opportunity_type IS NOT NULL
      GROUP BY opportunity_type ORDER BY cnt DESC
    SQL

    # ── SF Top Accounts ──────────────────────────────────────────────────────
    @sf_accounts = conn.select_all(<<~SQL).to_a
      SELECT account_name, customer_segment, account_owner,
             total_subscriptions, total_orders,
             total_mrr_zmw::bigint AS total_mrr_zmw,
             total_nrr_zmw::bigint AS total_nrr_zmw,
             accepted_count, delivered_count, in_qualification_count,
             rejected_count, not_required_count, in_organic_count, new_logo_count
      FROM vw_sf_accounts
      ORDER BY total_mrr_zmw DESC NULLS LAST
      LIMIT 50
    SQL

    # ── SF KAMs ─────────────────────────────────────────────────────────────
    @sf_kams = conn.select_all(<<~SQL).to_a
      SELECT account_owner, total_subscriptions, accounts_managed,
             total_orders, total_mrr_zmw::bigint AS total_mrr_zmw,
             total_nrr_zmw::bigint AS total_nrr_zmw,
             accepted_count, delivered_count, in_qualification_count,
             in_organic_count,
             round(delivery_completion_pct,1) AS delivery_completion_pct
      FROM vw_sf_by_kam
      ORDER BY total_mrr_zmw DESC NULLS LAST
      LIMIT 40
    SQL

    # ── Bridge funnel ────────────────────────────────────────────────────────
    @bridge_funnel = conn.select_one(<<~SQL)
      SELECT
        count(*)                                                        AS sf_total,
        count(CASE WHEN delivery_required THEN 1 END)                  AS needs_delivery,
        count(CASE WHEN sf_status='Accepted by Service Delivery' THEN 1 END) AS accepted,
        count(CASE WHEN in_organic THEN 1 END)                         AS in_organic,
        count(CASE WHEN is_delivered THEN 1 END)                       AS delivered,
        coalesce(sum(CASE WHEN sf_status='Accepted by Service Delivery' AND NOT in_organic THEN mrr_zmw ELSE 0 END),0)::bigint AS gap_mrr
      FROM vw_sf_pipeline WHERE is_fy27
    SQL

    # ── Delivery Gap ─────────────────────────────────────────────────────────
    @delivery_gap = conn.select_all(<<~SQL).to_a
      SELECT order_number, account_name, customer_segment, sf_status,
             opportunity_type, account_owner,
             mrr_zmw::bigint AS mrr_zmw, nrr_zmw::bigint AS nrr_zmw,
             days_since_sf_created, month_year
      FROM vw_sf_delivery_gap
      ORDER BY mrr_zmw DESC NULLS LAST
      LIMIT 100
    SQL

    # ── Organic dropdown lists for filters ───────────────────────────────────
    @org_assignees_list = conn.select_all(
      "SELECT DISTINCT assignee_name FROM vw_fact_all_orders WHERE NOT is_closed AND assignee_name IS NOT NULL ORDER BY assignee_name"
    ).map { |r| r['assignee_name'] }
    @org_statuses_list = conn.select_all(
      "SELECT DISTINCT status_name FROM vw_fact_all_orders WHERE NOT is_closed AND status_name IS NOT NULL ORDER BY status_name"
    ).map { |r| r['status_name'] }
    @org_accounts_list = conn.select_all(
      "SELECT DISTINCT account FROM vw_fact_all_orders WHERE NOT is_closed AND account IS NOT NULL ORDER BY account LIMIT 200"
    ).map { |r| r['account'] }
    @org_opp_types_list = conn.select_all(
      "SELECT DISTINCT opportunity_type FROM vw_fact_all_orders WHERE NOT is_closed AND opportunity_type IS NOT NULL ORDER BY opportunity_type"
    ).map { |r| r['opportunity_type'] }

    # ── Organic Summary ──────────────────────────────────────────────────────
    @organic_summary = conn.select_one(<<~SQL)
      SELECT
        count(*)                                              AS total_open,
        count(CASE WHEN active_wip THEN 1 END)               AS active_wip,
        count(CASE WHEN is_overdue THEN 1 END)               AS overdue,
        coalesce(sum(mrr_zmw),0)::bigint                     AS mrr_zmw,
        coalesce(sum(nrr_zmw),0)::bigint                     AS nrr_zmw,
        coalesce(sum(round(mrr_usd,0)),0)::bigint            AS mrr_usd,
        coalesce(sum(round(nrr_usd,0)),0)::bigint            AS nrr_usd,
        count(CASE WHEN tracker_id=14 THEN 1 END)            AS commercial_count,
        count(CASE WHEN tracker_id=18 THEN 1 END)            AS c2_count
      FROM vw_fact_all_orders WHERE NOT is_closed
    SQL

    # ── Organic Monthly intake ───────────────────────────────────────────────
    @organic_monthly = conn.select_all(<<~SQL).to_a
      SELECT to_char(created_date,'YYYY-MM') AS month_year, count(*) AS cnt
      FROM vw_fact_all_orders
      GROUP BY to_char(created_date,'YYYY-MM')
      ORDER BY month_year
    SQL

    # ── Organic opp types ────────────────────────────────────────────────────
    @organic_opp_types = conn.select_all(<<~SQL).to_a
      SELECT coalesce(opportunity_type,'Unknown') AS opportunity_type, count(*) AS cnt
      FROM vw_fact_all_orders WHERE NOT is_closed
      GROUP BY opportunity_type ORDER BY cnt DESC
    SQL

    # ── Organic assignees ────────────────────────────────────────────────────
    @organic_assignees = conn.select_all(<<~SQL).to_a
      SELECT coalesce(assignee_name,'Unassigned') AS assignee_name, count(*) AS cnt
      FROM vw_fact_all_orders WHERE NOT is_closed
      GROUP BY assignee_name ORDER BY cnt DESC LIMIT 10
    SQL

    # ── Organic status breakdown ─────────────────────────────────────────────
    @organic_statuses = conn.select_all(<<~SQL).to_a
      SELECT status_name, count(*) AS cnt
      FROM vw_fact_all_orders WHERE NOT is_closed
      GROUP BY status_name ORDER BY cnt DESC
    SQL

    # ── Organic all open orders ──────────────────────────────────────────────
    @organic_orders = conn.select_all(<<~SQL).to_a
      SELECT issue_id, tracker_name, account, order_number, opportunity_type,
             opportunity_name, status_name, assignee_name,
             mrr_zmw::bigint AS mrr_zmw, nrr_zmw::bigint AS nrr_zmw,
             round(mrr_usd,0)::bigint AS mrr_usd, round(nrr_usd,0)::bigint AS nrr_usd,
             age_days, is_overdue, active_wip, created_date
      FROM vw_fact_all_orders WHERE NOT is_closed
      ORDER BY mrr_zmw DESC NULLS LAST
      LIMIT 200
    SQL

    # ── Organic top accounts by MRR ──────────────────────────────────────────
    @organic_top_accounts = conn.select_all(<<~SQL).to_a
      SELECT account, coalesce(sum(mrr_zmw),0)::bigint AS mrr_zmw
      FROM vw_fact_all_orders WHERE NOT is_closed AND account IS NOT NULL
      GROUP BY account ORDER BY mrr_zmw DESC LIMIT 12
    SQL

    # ── Active WIP ───────────────────────────────────────────────────────────
    @organic_wip = conn.select_all(<<~SQL).to_a
      SELECT issue_id, tracker_name, account, order_number, opportunity_name,
             status_name, assignee_name, mrr_zmw::bigint AS mrr_zmw, nrr_zmw::bigint AS nrr_zmw,
             round(mrr_usd,0)::bigint AS mrr_usd, round(nrr_usd,0)::bigint AS nrr_usd,
             due_date, age_days, is_closed
      FROM vw_fact_all_orders
      WHERE active_wip AND NOT is_closed
      ORDER BY mrr_zmw DESC NULLS LAST
    SQL

    # ── SLA summary ──────────────────────────────────────────────────────────
    @sla_summary = conn.select_one(<<~SQL)
      SELECT
        count(*)                                AS total_records,
        count(CASE WHEN breached THEN 1 END)    AS breached_count,
        count(CASE WHEN NOT breached THEN 1 END) AS on_time_count,
        round(avg(CASE WHEN breached THEN hours_in_status END),1) AS avg_breach_hours
      FROM vw_fact_sla
    SQL

    # ── SLA avg hours by status ──────────────────────────────────────────────
    @sla_by_status = conn.select_all(<<~SQL).to_a
      SELECT status_name,
             round(avg(hours_in_status),1) AS avg_hours,
             count(CASE WHEN breached THEN 1 END) AS breached,
             count(CASE WHEN NOT breached THEN 1 END) AS on_time
      FROM vw_fact_sla
      WHERE hours_in_status IS NOT NULL
      GROUP BY status_name ORDER BY avg_hours DESC LIMIT 10
    SQL

    # ── Bridge coverage by month ──────────────────────────────────────────────
    @bridge_monthly = conn.select_all(<<~SQL).to_a
      SELECT month_year, total_subscriptions AS subs, organic_count AS organic
      FROM vw_sf_monthly ORDER BY period_start
    SQL

    # ── Gap by KAM ───────────────────────────────────────────────────────────
    @gap_by_kam = conn.select_all(<<~SQL).to_a
      SELECT account_owner AS kam, coalesce(sum(mrr_zmw),0)::bigint AS gap_mrr
      FROM vw_sf_delivery_gap
      WHERE account_owner IS NOT NULL
      GROUP BY account_owner ORDER BY gap_mrr DESC LIMIT 10
    SQL

    # Build JSON payloads for JS
    @sf_json = build_sf_json
    @organic_json = build_organic_json
    @bridge_json = build_bridge_json
    @generated_at = Time.current.strftime('%d %b %Y %H:%M')
  end

  # ── AJAX filter endpoint ─────────────────────────────────────────────────────
  # GET /snow_organic_dashboard/filter?segment=&kam=&sf_status=&tracker=
  def filter
    conn = ActiveRecord::Base.connection

    # Collect multi-select arrays — JS sends param[]=v1&param[]=v2; Rails parses as params[:param] = [v1,v2]
    segs    = Array(params[:segment]).compact.reject(&:empty?)
    kams    = Array(params[:kam]).compact.reject(&:empty?)
    sf_sts  = Array(params[:sf_status]).compact.reject(&:empty?)
    tids    = Array(params[:tracker]).compact.reject(&:empty?).map(&:to_i).select(&:positive?)

    # SQL IN-clause helper
    in_q = ->(col, vals) { "#{col} IN (#{vals.map { |v| conn.quote(v) }.join(',')})" }

    # SF pipeline WHERE (all filters apply)
    sf_parts = ["is_fy27"]
    sf_parts << in_q.("customer_segment", segs)  if segs.any?
    sf_parts << in_q.("account_owner", kams)      if kams.any?
    sf_parts << in_q.("sf_status", sf_sts)        if sf_sts.any?
    sf_w = sf_parts.join(" AND ")

    # Accounts/KAM view WHERE (segment + kam only — views are pre-aggregated across statuses)
    acct_parts = []
    acct_parts << in_q.("customer_segment", segs) if segs.any?
    acct_parts << in_q.("account_owner", kams)    if kams.any?
    acct_w = acct_parts.any? ? acct_parts.join(" AND ") : "1=1"
    kam_w  = kams.any? ? in_q.("account_owner", kams) : "1=1"

    # Gap view WHERE
    gap_parts = []
    gap_parts << in_q.("account_owner", kams)  if kams.any?
    gap_parts << in_q.("sf_status", sf_sts)    if sf_sts.any?
    gap_w = gap_parts.any? ? gap_parts.join(" AND ") : "1=1"

    # Organic WHERE
    org_parts = ["NOT is_closed"]
    org_parts << "tracker_id IN (#{tids.join(',')})" if tids.any?
    assignees    = Array(params[:assignee]).compact.reject(&:empty?)
    org_statuses = Array(params[:org_status]).compact.reject(&:empty?)
    accounts     = Array(params[:account]).compact.reject(&:empty?)
    opp_types    = Array(params[:opp_type]).compact.reject(&:empty?)
    active_wip_f = params[:active_wip] == 'true'
    overdue_only = params[:overdue_only] == 'true'
    order_num    = params[:order_number].presence
    req_num      = params[:request_number].presence
    acct_num     = params[:acct_number].presence
    date_from    = params[:date_from].presence
    date_to      = params[:date_to].presence
    org_parts << in_q.("assignee_name", assignees)     if assignees.any?
    org_parts << in_q.("status_name", org_statuses)    if org_statuses.any?
    org_parts << "active_wip = true"                   if active_wip_f
    org_parts << "is_overdue = true"                   if overdue_only
    org_parts << in_q.("account", accounts)            if accounts.any?
    org_parts << in_q.("opportunity_type", opp_types)  if opp_types.any?
    org_parts << "order_number ILIKE #{conn.quote('%'+order_num+'%')}"   if order_num
    org_parts << "snow_request_no ILIKE #{conn.quote('%'+req_num+'%')}"  if req_num
    org_parts << "account_number ILIKE #{conn.quote('%'+acct_num+'%')}"  if acct_num
    org_parts << "created_date >= #{conn.quote(date_from)}"              if date_from
    org_parts << "created_date <= #{conn.quote(date_to)}"                if date_to
    org_w     = org_parts.join(" AND ")
    # WIP queries include closed issues (is_closed=true counts as "delivered")
    wip_parts = org_parts.reject { |p| p == "NOT is_closed" }
    wip_org_w = wip_parts.any? ? wip_parts.join(" AND ") : "1=1"

    # SLA extra condition (subquery into fact_all_orders for tracker filter)
    sla_extra = tids.any? ? " AND issue_id IN (SELECT issue_id FROM vw_fact_all_orders WHERE tracker_id IN (#{tids.join(',')}))" : ""

    sf_summary = conn.select_one(<<~SQL)
      SELECT count(*) AS total_subscriptions,
        count(DISTINCT order_number) AS total_orders,
        count(DISTINCT account_name) AS total_accounts,
        count(DISTINCT CASE WHEN is_new_logo THEN account_name END) AS new_logo_accounts,
        count(DISTINCT CASE WHEN is_new_logo THEN order_number END) AS new_logo_orders,
        coalesce(sum(mrr_zmw),0)::bigint AS total_mrr_zmw,
        coalesce(sum(nrr_zmw),0)::bigint AS total_nrr_zmw,
        coalesce(sum(CASE WHEN is_new_logo THEN mrr_zmw ELSE 0 END),0)::bigint AS new_logo_mrr_zmw,
        count(CASE WHEN sf_status='Service Delivered' THEN 1 END) AS delivered_count,
        count(CASE WHEN sf_status='Accepted by Service Delivery' THEN 1 END) AS accepted_count,
        count(CASE WHEN sf_status='Rejected by Service Delivery' THEN 1 END) AS rejected_count,
        count(CASE WHEN sf_status='Sent for Service Qualification' THEN 1 END) AS in_qual_count,
        count(CASE WHEN sf_status='Service Delivery is not required' THEN 1 END) AS not_required_count,
        coalesce(sum(CASE WHEN sf_status='Accepted by Service Delivery' THEN mrr_zmw ELSE 0 END),0)::bigint AS accepted_mrr,
        coalesce(sum(CASE WHEN sf_status='Sent for Service Qualification' THEN mrr_zmw ELSE 0 END),0)::bigint AS qual_mrr,
        coalesce(sum(CASE WHEN sf_status='Service Delivered' THEN mrr_zmw ELSE 0 END),0)::bigint AS delivered_mrr,
        coalesce(sum(CASE WHEN sf_status='Rejected by Service Delivery' THEN mrr_zmw ELSE 0 END),0)::bigint AS rejected_mrr
      FROM vw_sf_pipeline WHERE #{sf_w}
    SQL

    # Monthly aggregated direct from pipeline (supports all filters including segment/KAM/status)
    sf_monthly = conn.select_all(<<~SQL).to_a
      SELECT month_year,
        count(*) AS total_subscriptions,
        count(DISTINCT order_number) AS total_orders,
        count(DISTINCT account_name) AS accounts,
        coalesce(sum(mrr_zmw),0)::bigint AS mrr_zmw,
        coalesce(sum(nrr_zmw),0)::bigint AS nrr_zmw,
        count(CASE WHEN sf_status='Accepted by Service Delivery' THEN 1 END) AS accepted_count,
        count(CASE WHEN sf_status='Service Delivered' THEN 1 END) AS delivered_count,
        count(CASE WHEN in_organic THEN 1 END) AS organic_count,
        count(DISTINCT CASE WHEN is_new_logo THEN account_name END) AS new_logo_accounts,
        count(DISTINCT CASE WHEN is_new_logo THEN order_number END) AS new_logo_orders,
        coalesce(sum(CASE WHEN is_new_logo THEN mrr_zmw ELSE 0 END),0)::bigint AS new_logo_mrr_zmw
      FROM vw_sf_pipeline WHERE #{sf_w} AND month_year IS NOT NULL
      GROUP BY month_year ORDER BY month_year
    SQL

    sf_statuses = conn.select_all(<<~SQL).to_a
      SELECT sf_status, count(*) AS cnt, coalesce(sum(mrr_zmw),0)::bigint AS mrr
      FROM vw_sf_pipeline WHERE #{sf_w} AND sf_status IS NOT NULL
      GROUP BY sf_status ORDER BY cnt DESC
    SQL

    sf_opp_types = conn.select_all(<<~SQL).to_a
      SELECT opportunity_type, count(*) AS cnt
      FROM vw_sf_pipeline WHERE #{sf_w} AND opportunity_type IS NOT NULL
      GROUP BY opportunity_type ORDER BY cnt DESC
    SQL

    sf_accounts = conn.select_all(<<~SQL).to_a
      SELECT account_name, customer_segment, account_owner,
        total_subscriptions, total_orders,
        total_mrr_zmw::bigint AS total_mrr_zmw, total_nrr_zmw::bigint AS total_nrr_zmw,
        accepted_count, delivered_count, in_qualification_count,
        rejected_count, not_required_count, in_organic_count, new_logo_count
      FROM vw_sf_accounts WHERE #{acct_w}
      ORDER BY total_mrr_zmw DESC NULLS LAST LIMIT 50
    SQL

    sf_kams = conn.select_all(<<~SQL).to_a
      SELECT account_owner, total_subscriptions, accounts_managed, total_orders,
        total_mrr_zmw::bigint AS total_mrr_zmw, total_nrr_zmw::bigint AS total_nrr_zmw,
        accepted_count, delivered_count, in_qualification_count, in_organic_count,
        round(delivery_completion_pct,1) AS delivery_completion_pct
      FROM vw_sf_by_kam WHERE #{kam_w}
      ORDER BY total_mrr_zmw DESC NULLS LAST LIMIT 40
    SQL

    bridge_funnel = conn.select_one(<<~SQL)
      SELECT count(*) AS sf_total,
        count(CASE WHEN delivery_required THEN 1 END) AS needs_delivery,
        count(CASE WHEN sf_status='Accepted by Service Delivery' THEN 1 END) AS accepted,
        count(CASE WHEN in_organic THEN 1 END) AS in_organic,
        count(CASE WHEN is_delivered THEN 1 END) AS delivered,
        coalesce(sum(CASE WHEN sf_status='Accepted by Service Delivery' AND NOT in_organic THEN mrr_zmw ELSE 0 END),0)::bigint AS gap_mrr
      FROM vw_sf_pipeline WHERE #{sf_w}
    SQL

    delivery_gap = conn.select_all(<<~SQL).to_a
      SELECT order_number, account_name, customer_segment, sf_status,
        opportunity_type, account_owner,
        mrr_zmw::bigint AS mrr_zmw, nrr_zmw::bigint AS nrr_zmw,
        days_since_sf_created, month_year
      FROM vw_sf_delivery_gap WHERE #{gap_w}
      ORDER BY mrr_zmw DESC NULLS LAST LIMIT 100
    SQL

    bridge_monthly = conn.select_all(<<~SQL).to_a
      SELECT month_year,
        count(*) AS subs,
        count(CASE WHEN in_organic THEN 1 END) AS organic
      FROM vw_sf_pipeline WHERE #{sf_w} AND month_year IS NOT NULL
      GROUP BY month_year ORDER BY month_year
    SQL

    gap_by_kam = conn.select_all(<<~SQL).to_a
      SELECT account_owner AS kam, coalesce(sum(mrr_zmw),0)::bigint AS gap_mrr
      FROM vw_sf_delivery_gap WHERE #{gap_w} AND account_owner IS NOT NULL
      GROUP BY account_owner ORDER BY gap_mrr DESC LIMIT 10
    SQL

    organic_summary = conn.select_one(<<~SQL)
      SELECT count(*) AS total_open,
        count(CASE WHEN active_wip THEN 1 END) AS active_wip,
        count(CASE WHEN is_overdue THEN 1 END) AS overdue,
        coalesce(sum(mrr_zmw),0)::bigint AS mrr_zmw,
        coalesce(sum(nrr_zmw),0)::bigint AS nrr_zmw,
        coalesce(sum(round(mrr_usd,0)),0)::bigint AS mrr_usd,
        coalesce(sum(round(nrr_usd,0)),0)::bigint AS nrr_usd,
        count(CASE WHEN tracker_id=14 THEN 1 END) AS commercial_count,
        count(CASE WHEN tracker_id=18 THEN 1 END) AS c2_count
      FROM vw_fact_all_orders WHERE #{org_w}
    SQL

    organic_monthly = conn.select_all(<<~SQL).to_a
      SELECT to_char(created_date,'YYYY-MM') AS month_year, count(*) AS cnt
      FROM vw_fact_all_orders WHERE #{org_w}
      GROUP BY to_char(created_date,'YYYY-MM') ORDER BY month_year
    SQL

    organic_opp_types = conn.select_all(<<~SQL).to_a
      SELECT coalesce(opportunity_type,'Unknown') AS opportunity_type, count(*) AS cnt
      FROM vw_fact_all_orders WHERE #{org_w}
      GROUP BY opportunity_type ORDER BY cnt DESC
    SQL

    organic_assignees = conn.select_all(<<~SQL).to_a
      SELECT coalesce(assignee_name,'Unassigned') AS assignee_name, count(*) AS cnt
      FROM vw_fact_all_orders WHERE #{org_w}
      GROUP BY assignee_name ORDER BY cnt DESC LIMIT 10
    SQL

    organic_statuses = conn.select_all(<<~SQL).to_a
      SELECT status_name, count(*) AS cnt
      FROM vw_fact_all_orders WHERE #{org_w}
      GROUP BY status_name ORDER BY cnt DESC
    SQL

    organic_orders = conn.select_all(<<~SQL).to_a
      SELECT issue_id, tracker_name, account, order_number, opportunity_type,
        opportunity_name, status_name, assignee_name,
        mrr_zmw::bigint AS mrr_zmw, nrr_zmw::bigint AS nrr_zmw,
        round(mrr_usd,0)::bigint AS mrr_usd, round(nrr_usd,0)::bigint AS nrr_usd,
        age_days, is_overdue, active_wip, created_date
      FROM vw_fact_all_orders WHERE #{org_w}
      ORDER BY mrr_zmw DESC NULLS LAST LIMIT 200
    SQL

    organic_top_accounts = conn.select_all(<<~SQL).to_a
      SELECT account, coalesce(sum(mrr_zmw),0)::bigint AS mrr_zmw
      FROM vw_fact_all_orders WHERE #{org_w} AND account IS NOT NULL
      GROUP BY account ORDER BY mrr_zmw DESC LIMIT 12
    SQL

    wip_year  = params[:wip_year].to_i.nonzero?
    wip_month = params[:wip_month].to_i.nonzero?
    wip_meta  = nil

    organic_wip = if wip_year && wip_month
      target   = SnowMonthlyTarget.for_month(wip_year, wip_month)
      cf_awip  = IssueCustomField.find_by(name: 'Active WIP')

      if target&.locked?
        locked_ids = target.locked_issue_ids.map(&:to_i)

        # Uplift: closed WIP issues that closed within the month after lock
        closed_status_ids = IssueStatus.where("name LIKE 'Closed%'").pluck(:id)
        month_end         = Date.new(wip_year, wip_month, 1).end_of_month.end_of_day
        uplift_ids = if cf_awip && locked_ids.any?
          Issue.where(tracker_id: [14, 18], status_id: closed_status_ids)
               .joins(:custom_values)
               .where(custom_values: { custom_field_id: cf_awip.id, value: '1' })
               .where.not(id: locked_ids)
               .to_a
               .select { |i|
                 t = SnowSlaTimer.where(issue_id: i.id, status_id: closed_status_ids).order(:entered_at).last
                 t&.entered_at&.between?(target.locked_at, month_end)
               }.map(&:id)
        else
          []
        end

        all_ids = (locked_ids + uplift_ids).uniq
        wip_meta = { locked: true, at: target.locked_at.strftime('%d %b %Y'),
                     by: target.locked_by&.name, target_count: target.target_count,
                     target_mrr: target.target_mrr_zmw.to_i, uplift_count: uplift_ids.size }

        all_ids.any? ? conn.select_all(<<~SQL).to_a : []
          SELECT issue_id, tracker_name, account, order_number, opportunity_name,
            status_name, assignee_name, mrr_zmw::bigint AS mrr_zmw, nrr_zmw::bigint AS nrr_zmw,
            round(mrr_usd,0)::bigint AS mrr_usd, round(nrr_usd,0)::bigint AS nrr_usd,
            due_date, age_days, is_closed,
            CASE WHEN issue_id IN (#{uplift_ids.any? ? uplift_ids.join(',') : '0'}) THEN true ELSE false END AS is_uplift
          FROM vw_fact_all_orders WHERE issue_id IN (#{all_ids.join(',')})
          ORDER BY mrr_zmw DESC NULLS LAST
        SQL
      else
        # Unlocked month — no snapshot exists, return empty so the user knows to lock first
        wip_meta = { locked: false, month_label: target&.month_label || "#{Date::MONTHNAMES[wip_month]} #{wip_year}" }
        []
      end
    else
      conn.select_all(<<~SQL).to_a
        SELECT issue_id, tracker_name, account, order_number, opportunity_name,
          status_name, assignee_name, mrr_zmw::bigint AS mrr_zmw, nrr_zmw::bigint AS nrr_zmw,
          round(mrr_usd,0)::bigint AS mrr_usd, round(nrr_usd,0)::bigint AS nrr_usd,
          due_date, age_days, is_closed, false AS is_uplift
        FROM vw_fact_all_orders WHERE active_wip AND #{org_w}
        ORDER BY mrr_zmw DESC NULLS LAST
      SQL
    end

    sla_summary = conn.select_one(<<~SQL)
      SELECT count(*) AS total_records,
        count(CASE WHEN breached THEN 1 END) AS breached_count,
        count(CASE WHEN NOT breached THEN 1 END) AS on_time_count,
        round(avg(CASE WHEN breached THEN hours_in_status END),1) AS avg_breach_hours
      FROM vw_fact_sla WHERE 1=1#{sla_extra}
    SQL

    sla_by_status = conn.select_all(<<~SQL).to_a
      SELECT status_name, round(avg(hours_in_status),1) AS avg_hours,
        count(CASE WHEN breached THEN 1 END) AS breached,
        count(CASE WHEN NOT breached THEN 1 END) AS on_time
      FROM vw_fact_sla WHERE hours_in_status IS NOT NULL#{sla_extra}
      GROUP BY status_name ORDER BY avg_hours DESC LIMIT 10
    SQL

    # Build JSON (same structure as index)
    s = sf_summary
    sf_json = {
      kpi: {
        total: s['total_subscriptions'].to_i, orders: s['total_orders'].to_i,
        accounts: s['total_accounts'].to_i, mrr_zmw: s['total_mrr_zmw'].to_i,
        nrr_zmw: s['total_nrr_zmw'].to_i, accepted: s['accepted_count'].to_i,
        delivered: s['delivered_count'].to_i, in_qual: s['in_qual_count'].to_i,
        rejected: s['rejected_count'].to_i, not_required: s['not_required_count'].to_i,
        accepted_mrr: s['accepted_mrr'].to_i, qual_mrr: s['qual_mrr'].to_i,
        delivered_mrr: s['delivered_mrr'].to_i, rejected_mrr: s['rejected_mrr'].to_i,
        new_logo_accounts: s['new_logo_accounts'].to_i, new_logo_orders: s['new_logo_orders'].to_i,
        new_logo_mrr: s['new_logo_mrr_zmw'].to_i
      },
      monthly: sf_monthly.map { |m| {
        m: m['month_year'], subs: m['total_subscriptions'].to_i, orders: m['total_orders'].to_i,
        accounts: m['accounts'].to_i, mrr: m['mrr_zmw'].to_i, nrr: m['nrr_zmw'].to_i,
        accepted: m['accepted_count'].to_i, delivered: m['delivered_count'].to_i,
        organic: m['organic_count'].to_i, nl_accts: m['new_logo_accounts'].to_i,
        nl_orders: m['new_logo_orders'].to_i, nl_mrr: m['new_logo_mrr_zmw'].to_i
      } },
      statuses: sf_statuses.map { |r| { s: r['sf_status'], cnt: r['cnt'].to_i, mrr: r['mrr'].to_i } },
      opp_types: sf_opp_types.map { |r| { t: r['opportunity_type'], cnt: r['cnt'].to_i } },
      top_accounts: sf_accounts.map { |a| {
        n: a['account_name'], seg: a['customer_segment'], kam: a['account_owner'],
        subs: a['total_subscriptions'].to_i, orders: a['total_orders'].to_i,
        mrr: a['total_mrr_zmw'].to_i, nrr: a['total_nrr_zmw'].to_i,
        accepted: a['accepted_count'].to_i, delivered: a['delivered_count'].to_i,
        in_qual: a['in_qualification_count'].to_i, rejected: a['rejected_count'].to_i,
        not_req: a['not_required_count'].to_i, organic: a['in_organic_count'].to_i
      } },
      kams: sf_kams.map { |k| {
        k: k['account_owner'], accts: k['accounts_managed'].to_i,
        subs: k['total_subscriptions'].to_i, orders: k['total_orders'].to_i,
        mrr: k['total_mrr_zmw'].to_i, nrr: k['total_nrr_zmw'].to_i,
        accepted: k['accepted_count'].to_i, delivered: k['delivered_count'].to_i,
        in_qual: k['in_qualification_count'].to_i, organic: k['in_organic_count'].to_i,
        pct: k['delivery_completion_pct'].to_f
      } },
      gap: delivery_gap.map { |g| {
        o: g['order_number'], a: g['account_name'], st: g['sf_status'],
        ot: g['opportunity_type'], kam: g['account_owner'],
        mrr: g['mrr_zmw'].to_i, nrr: g['nrr_zmw'].to_i,
        days: g['days_since_sf_created'].to_i, m: g['month_year']
      } }
    }

    sl = sla_summary
    breach_rate = sl['total_records'].to_i > 0 ?
      (sl['breached_count'].to_f / sl['total_records'].to_f * 100).round(1) : 0
    wip_mrr     = organic_wip.sum { |r| r['mrr_zmw'].to_i }
    wip_nrr     = organic_wip.sum { |r| r['nrr_zmw'].to_i }
    wip_mrr_usd = organic_wip.sum { |r| r['mrr_usd'].to_i }
    wip_nrr_usd = organic_wip.sum { |r| r['nrr_usd'].to_i }
    comm_wip    = organic_wip.count { |r| r['tracker_name'] == 'Commercial Orders' }
    c2_wip      = organic_wip.count { |r| r['tracker_name'] == 'C2' }
    avg_wip_age = organic_wip.any? ? (organic_wip.sum { |r| r['age_days'].to_i } / organic_wip.size.to_f).round : 0
    closed_wip  = organic_wip.count { |r| r['is_closed'] == true || r['is_closed'] == 't' }
    open_wip    = organic_wip.size - closed_wip
    os = organic_summary

    organic_json = {
      kpi: {
        total: os['total_open'].to_i, open: os['total_open'].to_i,
        wip: os['active_wip'].to_i, overdue: os['overdue'].to_i,
        mrr: os['mrr_zmw'].to_i, nrr: os['nrr_zmw'].to_i,
        mrr_usd: os['mrr_usd'].to_i, nrr_usd: os['nrr_usd'].to_i,
        sla_breach: breach_rate, sla_ok: sl['on_time_count'].to_i,
        sla_total: sl['total_records'].to_i,
        commercial: os['commercial_count'].to_i, c2: os['c2_count'].to_i
      },
      monthly: organic_monthly.map { |m| { m: m['month_year'], cnt: m['cnt'].to_i } },
      opp_types: organic_opp_types.map { |r| { t: r['opportunity_type'], n: r['cnt'].to_i } },
      assignees: organic_assignees.map { |r| { a: r['assignee_name'], n: r['cnt'].to_i } },
      statuses: organic_statuses.map { |r| { s: r['status_name'], n: r['cnt'].to_i } },
      sla_avg: sla_by_status.map { |r| {
        s: r['status_name'], h: r['avg_hours'].to_f,
        breached: r['breached'].to_i, on_time: r['on_time'].to_i
      } },
      top_accounts: organic_top_accounts.map { |r| { a: r['account'], mrr: r['mrr_zmw'].to_i } },
      all_orders: organic_orders.map { |o| {
        id: o['issue_id'], tracker: o['tracker_name'], account: o['account'],
        order: o['order_number'], opp: o['opportunity_type'], opp_name: o['opportunity_name'],
        status: o['status_name'], assignee: o['assignee_name'],
        mrr: o['mrr_zmw'].to_i, nrr: o['nrr_zmw'].to_i,
        mrr_usd: o['mrr_usd'].to_i, nrr_usd: o['nrr_usd'].to_i,
        age: o['age_days'].to_i, overdue: o['is_overdue'], wip: o['active_wip'],
        date: o['created_date']&.to_s
      } },
      wip: organic_wip.map { |o| {
        id: o['issue_id'], tracker: o['tracker_name'], account: o['account'],
        order: o['order_number'], opp_name: o['opportunity_name'],
        status: o['status_name'], assignee: o['assignee_name'],
        mrr: o['mrr_zmw'].to_i, nrr: o['nrr_zmw'].to_i,
        mrr_usd: o['mrr_usd'].to_i, nrr_usd: o['nrr_usd'].to_i,
        due: o['due_date']&.to_s, age: o['age_days'].to_i,
        uplift: o['is_uplift'] == true || o['is_uplift'] == 't',
        closed: o['is_closed'] == true || o['is_closed'] == 't'
      } },
      wip_mrr: wip_mrr, wip_nrr: wip_nrr,
      wip_mrr_usd: wip_mrr_usd, wip_nrr_usd: wip_nrr_usd,
      comm_wip: comm_wip, c2_wip: c2_wip, avg_wip_age: avg_wip_age,
      open_wip: open_wip, closed_wip: closed_wip,
      wip_meta: wip_meta
    }

    f = bridge_funnel
    total = f['sf_total'].to_i
    bridge_json = {
      funnel: [
        { label: 'SF Total FY27',                 val: total,                pct: 100,                                                            color: '#273c88' },
        { label: 'Needs Delivery (Accepted+Qual)', val: f['needs_delivery'].to_i, pct: total > 0 ? (f['needs_delivery'].to_f/total*100).round(1) : 0, color: '#3a5cbf' },
        { label: 'Accepted by Service Delivery',  val: f['accepted'].to_i,   pct: total > 0 ? (f['accepted'].to_f/total*100).round(1) : 0,       color: '#d97706' },
        { label: 'Matched to Organic Issue',      val: f['in_organic'].to_i, pct: total > 0 ? (f['in_organic'].to_f/total*100).round(1) : 0,     color: '#16a34a' },
        { label: 'Service Delivered (SF)',        val: f['delivered'].to_i,  pct: total > 0 ? (f['delivered'].to_f/total*100).round(1) : 0,      color: '#0891b2' }
      ],
      gap_mrr: f['gap_mrr'].to_i,
      monthly: bridge_monthly.map { |m| { m: m['month_year'], subs: m['subs'].to_i, organic: m['organic'].to_i } },
      gap_by_kam: gap_by_kam.map { |r| { kam: r['kam'], gap_mrr: r['gap_mrr'].to_i } }
    }

    render json: { sf: sf_json, organic: organic_json, bridge: bridge_json,
                   generated_at: Time.current.strftime('%d %b %Y %H:%M') }
  end

  def snow_live
    require 'net/http'
    settings  = Setting.plugin_redmine_snow_sync
    snow_url  = settings['snow_url'].to_s.chomp('/')
    username  = settings['snow_username'].to_s
    password  = settings['snow_password'].to_s

    snow_url = 'https://oneliquidsupport.service-now.com' if snow_url.blank?

    states  = Array(params[:state]).compact.reject(&:empty?)
    stages  = Array(params[:stage]).compact.reject(&:empty?)
    grps    = Array(params[:snow_group]).compact.reject(&:empty?)

    all_groups   = ['Zambia Service Delivery', 'Zambia Technical Services', 'Zambia Site Survey']
    active_groups = grps.any? ? grps : all_groups

    # Map display state names to SNow internal values
    state_val_map = {
      'Open' => '1', 'Work in Progress' => '2',
      'Closed Complete' => '3', 'Closed Incomplete' => '4', 'Closed Skipped' => '7'
    }

    base_q  = "assignment_group.nameIN#{active_groups.join(',')}"
    base_q += "^opened_at>=2026-03-01 00:00:00"
    if states.any?
      vals = states.map { |s| state_val_map[s] }.compact
      base_q += "^stateIN#{vals.join(',')}" if vals.any?
    end
    base_q += "^u_service_delivery_stageIN#{stages.join(',')}" if stages.any?

    by_stage     = snow_agg(snow_url, username, password, base_q, 'u_service_delivery_stage')
    by_state     = snow_agg(snow_url, username, password, base_q, 'state')
    by_group     = snow_agg(snow_url, username, password, base_q, 'assignment_group')
    top_accounts = snow_agg(snow_url, username, password, base_q, 'company.name', 25)

    records = snow_table(snow_url, username, password,
      base_q + '^ORDERBYDESCopened_at',
      'sys_id,number,short_description,state,u_service_delivery_stage,assignment_group,opened_at,due_date,company',
      200)

    now = Time.current
    overdue = records.count do |r|
      due = r['due_date'].presence
      state_disp = r['state'].to_s
      begin
        due && Time.parse(due) < now && ['Open', 'Work in Progress'].include?(state_disp)
      rescue
        false
      end
    end

    monthly = records.group_by { |r|
      begin; Date.parse(r['opened_at'].to_s).strftime('%Y-%m'); rescue; nil; end
    }.reject { |k, _| k.nil? }.sort.map { |m, recs| { m: m, cnt: recs.size } }

    render json: {
      by_stage:     by_stage.map     { |r| { stage: r['field_val'].presence || 'Unknown', cnt: r['cnt'] } },
      by_state:     by_state.map     { |r| { state: r['field_val'].presence || 'Unknown', cnt: r['cnt'] } },
      by_group:     by_group.map     { |r| { group: r['field_val'].presence || 'Unknown', cnt: r['cnt'] } },
      top_accounts: top_accounts.first(20).map { |r| { name: r['field_val'].presence || 'Unknown', cnt: r['cnt'] } },
      monthly:      monthly,
      requests:     records.first(150).map { |r|
        grp_val = r['assignment_group']
        grp_str = grp_val.is_a?(Hash) ? grp_val['display_value'].to_s : grp_val.to_s
        co_val  = r['company']
        co_str  = co_val.is_a?(Hash) ? co_val['display_value'].to_s : co_val.to_s
        {
          sys_id: r['sys_id'].to_s,
          num:    r['number'],
          desc:   r['short_description'].to_s.first(80),
          state:  r['state'],
          stage:  r['u_service_delivery_stage'],
          group:  grp_str,
          acct:   co_str,
          due:    r['due_date'].to_s,
          opened: r['opened_at'].to_s
        }
      },
      kpi: {
        total:    records.size,
        open:     records.count { |r| r['state'] == 'Open' },
        wip:      records.count { |r| r['state'] == 'Work in Progress' },
        complete: records.count { |r| r['state'] == 'Closed Complete' },
        overdue:  overdue
      },
      generated_at: Time.current.strftime('%d %b %Y %H:%M')
    }
  end

  def sd_report
    year  = params[:year].to_i.nonzero?  || Date.today.year
    month = params[:month].to_i.nonzero? || Date.today.month

    conn        = ActiveRecord::Base.connection
    month_start = Date.new(year, month, 1)
    month_end   = month_start.end_of_month
    today       = [Date.today, month_end].min

    target     = SnowMonthlyTarget.find_by(year: year, month: month)
    locked     = target&.locked?
    locked_ids = locked ? target.locked_issue_ids.map(&:to_i) : []

    on_hold_cust = [87]
    on_hold_lit  = [35, 85, 86]

    # Pipeline universe (mirrors the Excel source file): every open order plus
    # anything delivered or cancelled within the month.
    rows = conn.select_all(<<~SQL).to_a
      SELECT f.issue_id, f.tracker_id, f.status_id, f.media_type, f.active_wip,
             COALESCE(NULLIF(so.value,'')::date, f.created_date) AS received,
             f.date_signed_off, i.closed_on::date AS closed_on,
             COALESCE(f.mrr_usd,0)::float AS mrr, COALESCE(f.nrr_usd,0)::float AS nrr
      FROM vw_fact_all_orders f
      JOIN issues i ON i.id = f.issue_id
      LEFT JOIN custom_values so ON so.customized_type='Issue' AND so.customized_id=f.issue_id AND so.custom_field_id=75
      WHERE NOT f.is_closed
         OR f.date_signed_off BETWEEN #{conn.quote(month_start.to_s)} AND #{conn.quote(month_end.to_s)}
         OR (f.status_id = 89 AND i.closed_on >= #{conn.quote(month_start.to_s)} AND i.closed_on < #{conn.quote((month_end + 1).to_s)})
    SQL
    rows.each do |r|
      r['issue_id'] = r['issue_id'].to_i
      r['status_id'] = r['status_id'].to_i
      r['tracker_id'] = r['tracker_id'].to_i
      r['active_wip'] = [true, 't'].include?(r['active_wip'])
      r['received']        = r['received'] && Date.parse(r['received'].to_s)
      r['date_signed_off'] = r['date_signed_off'] && Date.parse(r['date_signed_off'].to_s)
    end

    sum = ->(set) {
      { count: set.size, mrr_usd: set.sum { |r| r['mrr'] }.round(2), nrr_usd: set.sum { |r| r['nrr'] }.round(2) }
    }
    add = ->(x, y) { { count: x[:count] + y[:count], mrr_usd: (x[:mrr_usd] + y[:mrr_usd]).round(2), nrr_usd: (x[:nrr_usd] + y[:nrr_usd]).round(2) } }

    build_section = ->(label, scope) {
      in_month = ->(d) { d && d >= month_start && d <= month_end }
      a_set   = scope.select { |r| in_month.(r['received']) }
      b_set   = scope - a_set
      d_set   = scope.select { |r| in_month.(r['date_signed_off']) && r['date_signed_off'] <= today }
      c_set   = scope.select { |r| r['status_id'] == 89 }
      aw_set  = locked ? scope.select { |r| locked_ids.include?(r['issue_id']) } : scope.select { |r| r['active_wip'] }
      ohc_set = scope.select { |r| on_hold_cust.include?(r['status_id']) }
      ohl_set = scope.select { |r| on_hold_lit.include?(r['status_id']) }

      aw = sum.(aw_set)
      d  = sum.(d_set)
      ach = ->(k) { aw[k].to_f > 0 ? (d[k] / aw[k].to_f * 100).round(1) : nil }
      {
        label:        label,
        backorder:    sum.(b_set),
        active_wip:   aw,
        target:       aw,
        added:        sum.(a_set),
        total_wip:    add.(sum.(b_set), sum.(a_set)),
        cancelled:    sum.(c_set),
        delivered:    d,
        achieved:     { count: ach.(:count), mrr_usd: ach.(:mrr_usd), nrr_usd: ach.(:nrr_usd) },
        on_hold_cust: sum.(ohc_set),
        on_hold_lit:  sum.(ohl_set),
        on_hold_total: add.(sum.(ohc_set), sum.(ohl_set))
      }
    }

    enterprise = build_section.('Enterprise/Commercial SD', rows)
    gpon       = build_section.('GPON SD', rows.select { |r| r['tracker_id'] == 14 && r['media_type'] == 'GPON' })

    daily = rows.select { |r| r['date_signed_off'] && r['date_signed_off'] >= month_start && r['date_signed_off'] <= month_end }
                .group_by { |r| r['date_signed_off'] }.sort.map { |dt, rs|
      { date: dt.to_s, enterprise: rs.size, gpon: rs.count { |r| r['tracker_id'] == 14 && r['media_type'] == 'GPON' } }
    }

    render json: {
      year: year, month: month,
      month_label: "#{Date::MONTHNAMES[month]} #{year}",
      month_short: Date::ABBR_MONTHNAMES[month],
      today: today.to_s,
      target_locked: locked,
      target_locked_at: target&.locked_at&.strftime('%d %b %Y'),
      sections: { enterprise: enterprise, gpon: gpon },
      daily: daily
    }
  end

  private

  SNOW_LIVE_USER = 'WebServiceUser'
  SNOW_LIVE_PASS = 's3rv1c3n0wR3ST'

  def snow_api_get(url, username, password, path, qparams = {})
    uri = URI("#{url}#{path}")
    uri.query = URI.encode_www_form(qparams.transform_values(&:to_s)) if qparams.any?
    req = Net::HTTP::Get.new(uri)
    req['Accept']       = 'application/json'
    req['Content-Type'] = 'application/json'
    req.basic_auth(username.presence || SNOW_LIVE_USER, password.presence || SNOW_LIVE_PASS)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.verify_mode  = OpenSSL::SSL::VERIFY_PEER
    http.read_timeout = 25
    http.open_timeout = 10
    res = http.request(req)
    JSON.parse(res.body)['result'] || []
  rescue => e
    Rails.logger.error "[SnowLive] API error (#{path}): #{e.message}"
    []
  end

  def snow_agg(url, username, password, query, group_by, limit = 50)
    results = snow_api_get(url, username, password, '/api/now/stats/sc_request',
      sysparm_query:    query,
      sysparm_count:    'true',
      sysparm_group_by: group_by,
      sysparm_limit:    limit
    )
    results.map do |r|
      { 'field_val' => r.dig('groupby_fields', 0, 'value').to_s,
        'cnt'       => r.dig('stats', 'count').to_i }
    end.sort_by { |r| -r['cnt'] }
  end

  def snow_table(url, username, password, query, fields, limit)
    snow_api_get(url, username, password, '/api/now/table/sc_request',
      sysparm_query:         query,
      sysparm_fields:        fields,
      sysparm_display_value: 'true',
      sysparm_limit:         limit
    )
  end

  def build_sf_json
    s = @sf_summary
    {
      kpi: {
        total:             s['total_subscriptions'].to_i,
        orders:            s['total_orders'].to_i,
        accounts:          s['total_accounts'].to_i,
        mrr_zmw:           s['total_mrr_zmw'].to_i,
        nrr_zmw:           s['total_nrr_zmw'].to_i,
        accepted:          s['accepted_count'].to_i,
        delivered:         s['delivered_count'].to_i,
        in_qual:           s['in_qual_count'].to_i,
        rejected:          s['rejected_count'].to_i,
        not_required:      s['not_required_count'].to_i,
        accepted_mrr:      s['accepted_mrr'].to_i,
        qual_mrr:          s['qual_mrr'].to_i,
        delivered_mrr:     s['delivered_mrr'].to_i,
        rejected_mrr:      s['rejected_mrr'].to_i,
        new_logo_accounts: s['new_logo_accounts'].to_i,
        new_logo_orders:   s['new_logo_orders'].to_i,
        new_logo_mrr:      s['new_logo_mrr_zmw'].to_i
      },
      monthly: @sf_monthly.map { |m|
        {
          m:           m['month_year'],
          subs:        m['total_subscriptions'].to_i,
          orders:      m['total_orders'].to_i,
          accounts:    m['accounts'].to_i,
          mrr:         m['mrr_zmw'].to_i,
          nrr:         m['nrr_zmw'].to_i,
          accepted:    m['accepted_count'].to_i,
          delivered:   m['delivered_count'].to_i,
          organic:     m['organic_count'].to_i,
          nl_accts:    m['new_logo_accounts'].to_i,
          nl_orders:   m['new_logo_orders'].to_i,
          nl_mrr:      m['new_logo_mrr_zmw'].to_i
        }
      },
      statuses: @sf_statuses.map { |r|
        { s: r['sf_status'], cnt: r['cnt'].to_i, mrr: r['mrr'].to_i }
      },
      opp_types: @sf_opp_types.map { |r|
        { t: r['opportunity_type'], cnt: r['cnt'].to_i }
      },
      top_accounts: @sf_accounts.map { |a|
        {
          n:         a['account_name'],
          seg:       a['customer_segment'],
          kam:       a['account_owner'],
          subs:      a['total_subscriptions'].to_i,
          orders:    a['total_orders'].to_i,
          mrr:       a['total_mrr_zmw'].to_i,
          nrr:       a['total_nrr_zmw'].to_i,
          accepted:  a['accepted_count'].to_i,
          delivered: a['delivered_count'].to_i,
          in_qual:   a['in_qualification_count'].to_i,
          rejected:  a['rejected_count'].to_i,
          not_req:   a['not_required_count'].to_i,
          organic:   a['in_organic_count'].to_i
        }
      },
      kams: @sf_kams.map { |k|
        {
          k:         k['account_owner'],
          accts:     k['accounts_managed'].to_i,
          subs:      k['total_subscriptions'].to_i,
          orders:    k['total_orders'].to_i,
          mrr:       k['total_mrr_zmw'].to_i,
          nrr:       k['total_nrr_zmw'].to_i,
          accepted:  k['accepted_count'].to_i,
          delivered: k['delivered_count'].to_i,
          in_qual:   k['in_qualification_count'].to_i,
          organic:   k['in_organic_count'].to_i,
          pct:       k['delivery_completion_pct'].to_f
        }
      },
      gap: @delivery_gap.map { |g|
        {
          o:    g['order_number'],
          a:    g['account_name'],
          st:   g['sf_status'],
          ot:   g['opportunity_type'],
          kam:  g['account_owner'],
          mrr:  g['mrr_zmw'].to_i,
          nrr:  g['nrr_zmw'].to_i,
          days: g['days_since_sf_created'].to_i,
          m:    g['month_year']
        }
      }
    }.to_json
  end

  def build_organic_json
    s = @organic_summary
    wip_mrr     = @organic_wip.sum { |r| r['mrr_zmw'].to_i }
    wip_nrr     = @organic_wip.sum { |r| r['nrr_zmw'].to_i }
    wip_mrr_usd = @organic_wip.sum { |r| r['mrr_usd'].to_i }
    wip_nrr_usd = @organic_wip.sum { |r| r['nrr_usd'].to_i }
    comm_wip    = @organic_wip.count { |r| r['tracker_name'] == 'Commercial Orders' }
    c2_wip      = @organic_wip.count { |r| r['tracker_name'] == 'C2' }
    avg_wip_age = @organic_wip.any? ? (@organic_wip.sum { |r| r['age_days'].to_i } / @organic_wip.size.to_f).round : 0
    closed_wip  = @organic_wip.count { |r| r['is_closed'] == true || r['is_closed'] == 't' }
    open_wip    = @organic_wip.size - closed_wip

    sl = @sla_summary
    breach_rate = sl['total_records'].to_i > 0 ?
      (sl['breached_count'].to_f / sl['total_records'].to_f * 100).round(1) : 0

    {
      kpi: {
        total:       s['total_open'].to_i,
        open:        s['total_open'].to_i,
        wip:         s['active_wip'].to_i,
        overdue:     s['overdue'].to_i,
        mrr:         s['mrr_zmw'].to_i,
        nrr:         s['nrr_zmw'].to_i,
        mrr_usd:     s['mrr_usd'].to_i,
        nrr_usd:     s['nrr_usd'].to_i,
        sla_breach:  breach_rate,
        sla_ok:      sl['on_time_count'].to_i,
        sla_total:   sl['total_records'].to_i,
        commercial:  s['commercial_count'].to_i,
        c2:          s['c2_count'].to_i
      },
      monthly: @organic_monthly.map { |m|
        { m: m['month_year'], cnt: m['cnt'].to_i }
      },
      opp_types: @organic_opp_types.map { |r|
        { t: r['opportunity_type'], n: r['cnt'].to_i }
      },
      assignees: @organic_assignees.map { |r|
        { a: r['assignee_name'], n: r['cnt'].to_i }
      },
      statuses: @organic_statuses.map { |r|
        { s: r['status_name'], n: r['cnt'].to_i }
      },
      sla_avg: @sla_by_status.map { |r|
        { s: r['status_name'], h: r['avg_hours'].to_f,
          breached: r['breached'].to_i, on_time: r['on_time'].to_i }
      },
      top_accounts: @organic_top_accounts.map { |r|
        { a: r['account'], mrr: r['mrr_zmw'].to_i }
      },
      all_orders: @organic_orders.map { |o|
        {
          id:       o['issue_id'],
          tracker:  o['tracker_name'],
          account:  o['account'],
          order:    o['order_number'],
          opp:      o['opportunity_type'],
          opp_name: o['opportunity_name'],
          status:   o['status_name'],
          assignee: o['assignee_name'],
          mrr:      o['mrr_zmw'].to_i,
          nrr:      o['nrr_zmw'].to_i,
          mrr_usd:  o['mrr_usd'].to_i,
          nrr_usd:  o['nrr_usd'].to_i,
          age:      o['age_days'].to_i,
          overdue:  o['is_overdue'],
          wip:      o['active_wip'],
          date:     o['created_date']&.to_s
        }
      },
      wip: @organic_wip.map { |o|
        {
          id:       o['issue_id'],
          tracker:  o['tracker_name'],
          account:  o['account'],
          order:    o['order_number'],
          opp_name: o['opportunity_name'],
          status:   o['status_name'],
          assignee: o['assignee_name'],
          mrr:      o['mrr_zmw'].to_i,
          nrr:      o['nrr_zmw'].to_i,
          mrr_usd:  o['mrr_usd'].to_i,
          nrr_usd:  o['nrr_usd'].to_i,
          due:      o['due_date']&.to_s,
          age:      o['age_days'].to_i,
          closed:   o['is_closed'] == true || o['is_closed'] == 't'
        }
      },
      wip_mrr:     wip_mrr,
      wip_nrr:     wip_nrr,
      wip_mrr_usd: wip_mrr_usd,
      wip_nrr_usd: wip_nrr_usd,
      comm_wip:    comm_wip,
      c2_wip:      c2_wip,
      avg_wip_age: avg_wip_age,
      open_wip:    open_wip,
      closed_wip:  closed_wip
    }.to_json
  end

  def build_bridge_json
    f = @bridge_funnel
    total = f['sf_total'].to_i
    {
      funnel: [
        { label: 'SF Total FY27',                    val: total,                        pct: 100,                                                              color: '#273c88' },
        { label: 'Needs Delivery (Accepted+Qual)',    val: f['needs_delivery'].to_i,     pct: total > 0 ? (f['needs_delivery'].to_f/total*100).round(1) : 0,   color: '#3a5cbf' },
        { label: 'Accepted by Service Delivery',     val: f['accepted'].to_i,           pct: total > 0 ? (f['accepted'].to_f/total*100).round(1) : 0,         color: '#d97706' },
        { label: 'Matched to Organic Issue',         val: f['in_organic'].to_i,         pct: total > 0 ? (f['in_organic'].to_f/total*100).round(1) : 0,       color: '#16a34a' },
        { label: 'Service Delivered (SF)',           val: f['delivered'].to_i,          pct: total > 0 ? (f['delivered'].to_f/total*100).round(1) : 0,        color: '#0891b2' },
      ],
      gap_mrr:    f['gap_mrr'].to_i,
      monthly:    @bridge_monthly.map { |m| { m: m['month_year'], subs: m['subs'].to_i, organic: m['organic'].to_i } },
      gap_by_kam: @gap_by_kam.map { |r| { kam: r['kam'], gap_mrr: r['gap_mrr'].to_i } }
    }.to_json
  end
end
