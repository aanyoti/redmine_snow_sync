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
