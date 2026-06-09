class SnowLibreNmsController < ApplicationController
  before_action :require_login
  before_action :build_client

  # GET /snow_libre_nms/devices?q=term   → JSON array of matching devices
  def devices
    q = params[:q].to_s.downcase.strip
    all = @client.network_devices
    matches = q.length >= 2 ? all.select { |d| d[:name].downcase.include?(q) } : all
    render json: matches.first(30)
  end

  # GET /snow_libre_nms/ports?device_id=N  → JSON array of ports
  def ports
    device_id = params[:device_id].to_i
    return render json: [] unless device_id > 0

    ports = @client.ports(device_id).map do |p|
      {
        id:     p['port_id'],
        name:   p['ifName'],
        desc:   p['ifAlias'].presence || p['ifDescr'],
        status: p['ifOperStatus'],
      }
    end
    render json: ports
  end

  # GET /snow_libre_nms/locations  → JSON array of location name strings
  def locations
    render json: @client.locations
  end

  # GET /snow_libre_nms/bandwidth?device_ip=X.X.X.X&port=GigabitEthernetX/X/X/X.Y
  # Returns {bandwidth: "15 Mbps"} or {bandwidth: null}
  def bandwidth
    ip   = params[:device_ip].to_s.strip
    port = params[:port].to_s.strip
    return render json: { bandwidth: nil } if ip.blank? || port.blank?

    result = SnowSync::OxidizedClient.new.bandwidth_for(device_ip: ip, port: port)
    render json: result
  end

  private

  def build_client
    token = Setting.plugin_redmine_snow_sync['librenms_token'].to_s.strip
    if token.blank?
      render json: { error: 'LibreNMS token not configured' }, status: :service_unavailable
      return false
    end
    @client = SnowSync::LibreNmsClient.new(token)
  end
end
