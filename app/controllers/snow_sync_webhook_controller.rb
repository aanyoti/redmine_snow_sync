class SnowSyncWebhookController < ApplicationController
  skip_before_action :check_if_login_required
  skip_before_action :verify_authenticity_token

  def report
    unless valid_token?
      render json: { error: 'Unauthorized' }, status: :unauthorized
      return
    end

    sql = "SELECT * FROM commercial_orders_flat"
    if params[:updated_since].present?
      since = Time.parse(params[:updated_since]) rescue nil
      sql += " WHERE updated_on >= '#{since.utc.strftime('%Y-%m-%d %H:%M:%S')}'" if since
    end
    sql += " ORDER BY id DESC"

    rows = ActiveRecord::Base.connection.select_all(sql)
    render json: rows.to_a

  rescue => e
    Rails.logger.error "SnowSync Report: #{e.message}"
    render json: { error: 'Internal server error' }, status: :internal_server_error
  end

  def salesforce_sync
    unless valid_token?
      render json: { error: 'Unauthorized' }, status: :unauthorized
      return
    end

    records = JSON.parse(request.body.read)
    unless records.is_a?(Array)
      render json: { error: 'Expected a JSON array' }, status: :bad_request
      return
    end

    results = { processed: 0, upserted: 0, skipped: 0, errors: 0 }
    conn    = ActiveRecord::Base.connection

    records.each do |rec|
      results[:processed] += 1
      sid = rec['subscription_id'].to_s.strip
      if sid.blank?
        results[:skipped] += 1
        next
      end

      conn.execute(<<~SQL)
        INSERT INTO salesforce_orders (
          subscription_id, order_number, customer_order_number, lt_account_number,
          account_name, lt_opp_number, opportunity_type, customer_segment,
          subscription_number, subscription_name, primary_service_number,
          service_address, service_address_lookup, access_type, currency,
          contract_term, sf_status, change_type, upgraded_opportunity,
          differential_nrr_amount, differential_nrr_currency,
          differential_mrr_amount, differential_mrr_currency,
          operating_country, account_owner, service_delivery_engineer,
          service_delivery_manager, service_delivery_reason, delivery_milestones,
          milestone_target_date, adjusted_days_to_deliver, ltk_sdu_internal_process,
          case_number, case_owner, sf_subject, snow_request_number, sf_created_date,
          synced_at
        ) VALUES (
          #{conn.quote(sid)},
          #{conn.quote(rec['order_number'])},
          #{conn.quote(rec['customer_order_number'])},
          #{conn.quote(rec['lt_account_number'])},
          #{conn.quote(rec['account_name'])},
          #{conn.quote(rec['lt_opp_number'])},
          #{conn.quote(rec['opportunity_type'])},
          #{conn.quote(rec['customer_segment'])},
          #{conn.quote(rec['subscription_number'])},
          #{conn.quote(rec['subscription_name'])},
          #{conn.quote(rec['primary_service_number'])},
          #{conn.quote(rec['service_address'])},
          #{conn.quote(rec['service_address_lookup'])},
          #{conn.quote(rec['access_type'])},
          #{conn.quote(rec['currency'])},
          #{conn.quote(rec['contract_term'].to_s)},
          #{conn.quote(rec['sf_status'])},
          #{conn.quote(rec['change_type'])},
          #{conn.quote(rec['upgraded_opportunity'])},
          #{conn.quote(rec['differential_nrr_amount'].to_s)},
          #{conn.quote(rec['differential_nrr_currency'])},
          #{conn.quote(rec['differential_mrr_amount'].to_s)},
          #{conn.quote(rec['differential_mrr_currency'])},
          #{conn.quote(rec['operating_country'])},
          #{conn.quote(rec['account_owner'])},
          #{conn.quote(rec['service_delivery_engineer'])},
          #{conn.quote(rec['service_delivery_manager'])},
          #{conn.quote(rec['service_delivery_reason'])},
          #{conn.quote(rec['delivery_milestones'])},
          #{conn.quote(rec['milestone_target_date'].to_s)},
          #{conn.quote(rec['adjusted_days_to_deliver'].to_s)},
          #{conn.quote(rec['ltk_sdu_internal_process'])},
          #{conn.quote(rec['case_number'])},
          #{conn.quote(rec['case_owner'])},
          #{conn.quote(rec['sf_subject'])},
          #{conn.quote(rec['snow_request_number'])},
          #{conn.quote(rec['sf_created_date'].to_s)},
          NOW()
        )
        ON CONFLICT (subscription_id) DO UPDATE SET
          order_number                = EXCLUDED.order_number,
          customer_order_number       = EXCLUDED.customer_order_number,
          lt_account_number           = EXCLUDED.lt_account_number,
          account_name                = EXCLUDED.account_name,
          lt_opp_number               = EXCLUDED.lt_opp_number,
          opportunity_type            = EXCLUDED.opportunity_type,
          customer_segment            = EXCLUDED.customer_segment,
          subscription_number         = EXCLUDED.subscription_number,
          subscription_name           = EXCLUDED.subscription_name,
          primary_service_number      = EXCLUDED.primary_service_number,
          service_address             = EXCLUDED.service_address,
          service_address_lookup      = EXCLUDED.service_address_lookup,
          access_type                 = EXCLUDED.access_type,
          currency                    = EXCLUDED.currency,
          contract_term               = EXCLUDED.contract_term,
          sf_status                   = EXCLUDED.sf_status,
          change_type                 = EXCLUDED.change_type,
          upgraded_opportunity        = EXCLUDED.upgraded_opportunity,
          differential_nrr_amount     = EXCLUDED.differential_nrr_amount,
          differential_nrr_currency   = EXCLUDED.differential_nrr_currency,
          differential_mrr_amount     = EXCLUDED.differential_mrr_amount,
          differential_mrr_currency   = EXCLUDED.differential_mrr_currency,
          operating_country           = EXCLUDED.operating_country,
          account_owner               = EXCLUDED.account_owner,
          service_delivery_engineer   = EXCLUDED.service_delivery_engineer,
          service_delivery_manager    = EXCLUDED.service_delivery_manager,
          service_delivery_reason     = EXCLUDED.service_delivery_reason,
          delivery_milestones         = EXCLUDED.delivery_milestones,
          milestone_target_date       = EXCLUDED.milestone_target_date,
          adjusted_days_to_deliver    = EXCLUDED.adjusted_days_to_deliver,
          ltk_sdu_internal_process    = EXCLUDED.ltk_sdu_internal_process,
          case_number                 = EXCLUDED.case_number,
          case_owner                  = EXCLUDED.case_owner,
          sf_subject                  = EXCLUDED.sf_subject,
          snow_request_number         = EXCLUDED.snow_request_number,
          sf_created_date             = EXCLUDED.sf_created_date,
          synced_at                   = NOW();
      SQL
      results[:upserted] += 1

    rescue => e
      Rails.logger.warn "SnowSync SalesforceSync: error on #{sid}: #{e.message}"
      results[:errors] += 1
    end

    render json: results

  rescue JSON::ParserError => e
    render json: { error: "Invalid JSON: #{e.message}" }, status: :bad_request
  rescue => e
    Rails.logger.error "SnowSync SalesforceSync: #{e.message}"
    render json: { error: 'Internal server error' }, status: :internal_server_error
  end

  def salesforce_report
    unless valid_token?
      render json: { error: 'Unauthorized' }, status: :unauthorized
      return
    end

    sql = "SELECT * FROM commercial_orders_complete ORDER BY redmine_id DESC"
    rows = ActiveRecord::Base.connection.select_all(sql)
    render json: rows.to_a

  rescue => e
    Rails.logger.error "SnowSync SalesforceReport: #{e.message}"
    render json: { error: 'Internal server error' }, status: :internal_server_error
  end

  def retail_preview
    unless valid_token?
      render json: { error: 'Unauthorized' }, status: :unauthorized
      return
    end

    raw = request.body.read
    log_path = Rails.root.join('log', 'retail_preview.json')
    File.write(log_path, raw)
    Rails.logger.info "SnowSync RetailPreview: captured #{raw.bytesize} bytes to #{log_path}"

    begin
      records = JSON.parse(raw)
      sample  = records.is_a?(Array) ? records.first : records
      render json: {
        status:       'captured',
        record_count: records.is_a?(Array) ? records.length : 1,
        keys:         sample.is_a?(Hash) ? sample.keys : [],
        first_row:    sample
      }
    rescue JSON::ParserError => e
      render json: { status: 'captured_raw', error: e.message }
    end
  rescue => e
    Rails.logger.error "SnowSync RetailPreview: #{e.message}"
    render json: { error: 'Internal server error' }, status: :internal_server_error
  end

  def segments
    unless valid_token?
      render json: { error: 'Unauthorized' }, status: :unauthorized
      return
    end

    records = JSON.parse(request.body.read)
    unless records.is_a?(Array)
      render json: { error: 'Expected a JSON array' }, status: :bad_request
      return
    end

    results = SnowSync::SegmentEnricher.new.process(records)
    render json: results

  rescue JSON::ParserError => e
    render json: { error: "Invalid JSON: #{e.message}" }, status: :bad_request
  rescue => e
    Rails.logger.error "SnowSync Webhook: unexpected error: #{e.message}"
    render json: { error: 'Internal server error' }, status: :internal_server_error
  end

  private

  def valid_token?
    expected = Setting.plugin_redmine_snow_sync['webhook_token'].to_s
    return false if expected.blank?
    provided = request.headers['X-Webhook-Token'].to_s
    ActiveSupport::SecurityUtils.secure_compare(expected, provided)
  end
end
