class SnowPowerbiController < ApplicationController
  skip_before_action :check_if_login_required
  skip_before_action :verify_authenticity_token
  before_action :authenticate_token

  VIEWS = {
    # ── Organic (Redmine delivery) ──────────────────────────────
    'dim_status'             => 'vw_dim_status',
    'dim_tracker'            => 'vw_dim_tracker',
    'dim_user'               => 'vw_dim_user',
    'dim_version'            => 'vw_dim_version',
    'fact_issues'            => 'vw_fact_issues',
    'fact_commercial_orders' => 'vw_fact_commercial_orders',
    'fact_c2_orders'         => 'vw_fact_c2_orders',
    'fact_procurement'       => 'vw_fact_procurement',
    'fact_all_orders'        => 'vw_fact_all_orders',
    'fact_status_history'    => 'vw_fact_status_history',
    'fact_sla'               => 'vw_fact_sla',
    'fact_monthly_targets'   => 'vw_fact_monthly_targets',
    # ── Salesforce (CRM pipeline) ───────────────────────────────
    'sf_pipeline'            => 'vw_sf_pipeline',
    'sf_accounts'            => 'vw_sf_accounts',
    'sf_by_kam'              => 'vw_sf_by_kam',
    'sf_monthly'             => 'vw_sf_monthly',
    'sf_delivery_bridge'     => 'vw_sf_delivery_bridge',
    'sf_delivery_gap'        => 'vw_sf_delivery_gap',
    # ── Checklists ──────────────────────────────────────────────
    'checklist_compliance'   => 'vw_checklist_compliance',
  }.freeze

  # Fact tables that support ?updated_since incremental refresh
  INCREMENTAL_VIEWS = %w[
    vw_fact_issues vw_fact_commercial_orders vw_fact_c2_orders
    vw_fact_procurement vw_fact_all_orders vw_sf_pipeline
  ].freeze

  # GET /api/powerbi/:dataset
  def dataset
    view = VIEWS[params[:dataset]]
    unless view
      render json: { error: "Unknown dataset '#{params[:dataset]}'",
                     available: VIEWS.keys }, status: :not_found
      return
    end

    sql = "SELECT * FROM #{view}"

    # Optional incremental refresh — ?updated_since=2026-01-01
    if params[:updated_since].present?
      since = Time.parse(params[:updated_since]) rescue nil
      if since && INCREMENTAL_VIEWS.include?(view)
        date_col = view == 'vw_sf_pipeline' ? 'synced_at' : 'updated_date'
        sql += ActiveRecord::Base.sanitize_sql_array(
          [" WHERE #{date_col} >= ?", since.utc.to_date]
        )
      end
    end

    rows = ActiveRecord::Base.connection.select_all(sql)

    response.set_header('X-Row-Count', rows.count.to_s)
    response.set_header('X-Generated-At', Time.current.iso8601)

    render json: {
      dataset:      params[:dataset],
      row_count:    rows.count,
      generated_at: Time.current.iso8601,
      columns:      rows.columns,
      data:         rows.to_a
    }
  rescue => e
    Rails.logger.error "SnowPowerBI: #{params[:dataset]} — #{e.message}"
    render json: { error: 'Internal server error' }, status: :internal_server_error
  end

  # GET /api/powerbi — list available endpoints
  def index
    base = "#{request.base_url}/api/powerbi"
    render json: {
      auth:      'Header: X-Webhook-Token: <token>',
      endpoints: VIEWS.keys.map { |k| "GET #{base}/#{k}" },
      optional_param: '?updated_since=YYYY-MM-DD (fact tables only)'
    }
  end

  private

  def authenticate_token
    token = Setting.plugin_redmine_snow_sync['webhook_token'].to_s.strip

    # X-Webhook-Token header (existing integrations — cron, Power Automate)
    provided = request.headers['X-Webhook-Token'].to_s.strip

    # HTTP Basic Auth password (PowerBI Service credential store)
    if provided.blank? && request.headers['Authorization'].present?
      _, provided = ActionController::HttpAuthentication::Basic.user_name_and_password(request) rescue [nil, nil]
      provided = provided.to_s.strip
    end

    unless token.present? && provided.present? &&
           ActiveSupport::SecurityUtils.secure_compare(token, provided)
      response.headers['WWW-Authenticate'] = 'Basic realm="PowerBI API"'
      render json: { error: 'Unauthorized' }, status: :unauthorized
    end
  end
end
