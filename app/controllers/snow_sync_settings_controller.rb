class SnowSyncSettingsController < ApplicationController
  before_action :require_admin

  def index
    @settings = Setting.plugin_redmine_snow_sync
    @records  = SnowSyncRecord.recent
    @projects = Project.all.sorted
    @trackers = Tracker.sorted
    @stats    = {
      total:  SnowSyncRecord.count,
      ok:     SnowSyncRecord.where(sync_status: 'ok').count,
      errors: SnowSyncRecord.where(sync_status: 'error').count
    }
  end

  def update
    cfg = Setting.plugin_redmine_snow_sync
    Setting.plugin_redmine_snow_sync = cfg.merge(settings_params)
    flash[:notice] = l(:notice_successful_update)
    redirect_to snow_sync_settings_path
  end

  def run_now
    result = SnowSync::Importer.new.run
    render json: result
  end

  def recalculate_rates
    rate = Setting.plugin_redmine_snow_sync['zmw_usd_rate'].to_f
    rate = 27.50 if rate.zero?

    cf_ids = {
      nrr_zmw: IssueCustomField.find_by(name: 'NRR (ZMW)')&.id&.to_s,
      mrr_zmw: IssueCustomField.find_by(name: 'MRR (ZMW)')&.id&.to_s,
      nrr_usd: IssueCustomField.find_by(name: 'NRR (USD)')&.id&.to_s,
      mrr_usd: IssueCustomField.find_by(name: 'MRR (USD)')&.id&.to_s,
    }

    issue_ids = Attachment.where(container_type: 'Issue')
                          .where('filename ~* ?', 'CECLT.*\.pdf')
                          .distinct.pluck(:container_id)

    updated = 0
    skipped = 0

    Issue.where(id: issue_ids).find_each do |issue|
      att = issue.attachments.detect { |a| a.filename =~ /CECLT.*\.pdf/i }
      next unless att

      data = SnowSync::PdfExtractor.extract(att.diskfile) rescue {}
      if data.empty?
        skipped += 1
        next
      end

      currency = data[:currency] || 'ZMW'
      nrr_raw  = data[:nrr].to_s.gsub(',', '').to_f
      mrr_raw  = data[:mrr].to_s.gsub(',', '').to_f

      if currency == 'ZMW'
        nrr_zmw = data[:nrr];                          mrr_zmw = data[:mrr]
        nrr_usd = format('%.2f', nrr_raw / rate);      mrr_usd = format('%.2f', mrr_raw / rate)
      else
        nrr_usd = data[:nrr];                          mrr_usd = data[:mrr]
        nrr_zmw = format('%.2f', nrr_raw * rate);      mrr_zmw = format('%.2f', mrr_raw * rate)
      end

      updates = {
        cf_ids[:nrr_zmw] => nrr_zmw,
        cf_ids[:mrr_zmw] => mrr_zmw,
        cf_ids[:nrr_usd] => nrr_usd,
        cf_ids[:mrr_usd] => mrr_usd,
      }.reject { |k, v| k.nil? || v.nil? }

      issue.custom_field_values = updates
      issue.save(validate: false)
      updated += 1
    rescue => e
      Rails.logger.warn "SnowSync recalculate_rates: issue ##{issue.id} failed: #{e.message}"
      skipped += 1
    end

    render json: { updated: updated, skipped: skipped, rate: rate }
  end

  # Test credentials without saving — accepts username+password from the form
  # so both accounts can be tried before committing to one.
  def test_connection
    url      = params[:url].presence      || Setting.plugin_redmine_snow_sync['snow_url']
    username = params[:username].presence
    password = params[:password].presence

    if username.blank? || password.blank?
      return render json: { ok: false, message: 'Enter a username and password first.' }
    end

    result = SnowSync::ConnectionTest.run(url: url, username: username, password: password)
    render json: result
  end

  private

  def settings_params
    params.require(:settings).permit(
      :snow_url, :snow_username, :snow_password,
      :target_project_id, :target_tracker_id,
      :assignment_groups, :poll_states, :poll_delivery_stage,
      :field_account, :field_order, :field_service, :days_back,
      :zmw_usd_rate, :webhook_token, :opportunity_tracker_map, :teams_webhook_url, :teams_test_email
    )
  end
end
