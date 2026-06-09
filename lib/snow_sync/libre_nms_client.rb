require 'net/http'
require 'json'
require 'openssl'

module SnowSync
  class LibreNmsClient
    BASE = 'https://librenms.liquidtelecom.zm/api/v0'.freeze
    ROUTER_GROUPS = { 'Core Routers' => 1, 'Aggregation Routers' => 2, 'Metro Routers' => 4 }.freeze

    def initialize(token)
      @token = token
    end

    # Returns devices from the three router groups, slim JSON, cached 15 min.
    def network_devices
      Rails.cache.fetch('librenms_router_devices', expires_in: 15.minutes) do
        group_ids = fetch_group_device_ids
        return [] if group_ids.empty?

        all = get('devices')['devices'] || []
        all.select { |d| group_ids.include?(d['device_id']) }
           .map do |d|
             {
               id:       d['device_id'],
               name:     d['sysName'].to_s,
               hardware: d['hardware'].to_s,
               group:    group_ids[d['device_id']],
               ip:       d['ip'].to_s,
             }
           end
           .sort_by { |d| d[:name] }
      end
    rescue => e
      Rails.logger.warn "LibreNMS: network_devices failed — #{e.message}"
      []
    end

    # Returns ports for a given device_id.
    def ports(device_id)
      get("devices/#{device_id}/ports",
          columns: 'port_id,ifName,ifDescr,ifAlias,ifOperStatus')['ports'] || []
    rescue => e
      Rails.logger.warn "LibreNMS: ports(#{device_id}) failed — #{e.message}"
      []
    end

    # Returns named locations only (excludes raw coordinates), cached 30 min.
    def locations
      Rails.cache.fetch('librenms_locations', expires_in: 30.minutes) do
        all = get('resources/locations')['locations'] || []
        all.select { |l| l['location'].to_s.match?(/[A-Za-z]/) }
           .map    { |l| l['location'].to_s.strip }
           .uniq.sort
      end
    rescue => e
      Rails.logger.warn "LibreNMS: locations failed — #{e.message}"
      []
    end

    private

    # Returns hash of { device_id => group_label }
    def fetch_group_device_ids
      Rails.cache.fetch('librenms_group_ids', expires_in: 30.minutes) do
        result = {}
        ROUTER_GROUPS.each do |label, gid|
          ids = get("devicegroups/#{gid}")['devices'] || []
          ids.each { |entry| result[entry['device_id']] = label }
        end
        result
      end
    end

    def get(path, params = {})
      uri = URI("#{BASE}/#{path}")
      uri.query = URI.encode_www_form(params) if params.any?
      req = Net::HTTP::Get.new(uri)
      req['X-Auth-Token'] = @token

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      http.read_timeout = 10
      http.open_timeout = 5

      JSON.parse(http.request(req).body)
    end
  end
end
