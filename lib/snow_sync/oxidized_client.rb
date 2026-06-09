require 'net/http'
require 'json'

module SnowSync
  class OxidizedClient
    BASE = 'http://10.169.62.11:8888'.freeze

    # Returns {bandwidth: "15 Mbps"} or {bandwidth: nil} for a device IP + port.
    def bandwidth_for(device_ip:, port:)
      node = find_node_by_ip(device_ip)
      return { bandwidth: nil } unless node

      config = fetch_config(node[:group], node[:name])
      return { bandwidth: nil } if config.blank?

      bw = parse_bandwidth(config, port)
      { bandwidth: bw }
    rescue => e
      Rails.logger.warn "Oxidized: bandwidth_for(#{device_ip}, #{port}) — #{e.message}"
      { bandwidth: nil }
    end

    private

    # ── Node lookup ─────────────────────────────────────────────────────────

    def find_node_by_ip(ip)
      all_nodes.find { |n| n[:ip] == ip }
    end

    def all_nodes
      Rails.cache.fetch('oxidized_nodes', expires_in: 30.minutes) do
        body = get('nodes.json')
        JSON.parse(body).map { |n| { name: n['name'], ip: n['ip'], group: n['group'] } }
      end
    end

    # ── Config fetch (cached per device) ────────────────────────────────────

    def fetch_config(group, name)
      Rails.cache.fetch("oxidized_config_#{name}", expires_in: 30.minutes) do
        get("node/fetch/#{group}/#{name}")
      end
    end

    # ── Bandwidth parser ─────────────────────────────────────────────────────
    #
    # Follows the IOS XR config chain:
    #   interface GigX/X/X/X.Y
    #     service-policy output POLICY_NAME   ← find this
    #   !
    #   policy-map POLICY_NAME
    #     class class-default
    #       police rate N mbps|gbps|kbps|bps  ← extract this
    #
    # Returns nil if no service-policy or no police rate found.

    def parse_bandwidth(config, port_name)
      block = extract_interface_block(config, port_name)
      return nil unless block

      # Prefer output policy (egress = customer-facing rate); fall back to input
      policy_name = block.match(/service-policy output\s+(\S+)/i)&.[](1) ||
                    block.match(/service-policy input\s+(\S+)/i)&.[](1)
      return nil unless policy_name

      pm_block = extract_policy_map_block(config, policy_name)
      return nil unless pm_block

      # Look in class-default first, then anywhere in the policy-map
      class_default = pm_block.match(/class class-default\n(.*?)(?:^  !|\z)/m)&.[](1) || pm_block
      m = class_default.match(/police rate\s+(\d+(?:\.\d+)?)\s*(gbps|mbps|kbps|bps)?/i)
      return nil unless m

      # IOS XR: bare number with no unit defaults to bps
      unit = m[2].presence&.downcase || 'bps'
      format_mbps(m[1].to_f, unit)
    end

    def extract_interface_block(config, port_name)
      escaped = Regexp.escape(port_name)
      m = config.match(/^interface #{escaped}[^\n]*\n(.*?)^!/m)
      m ? m[1] : nil
    end

    def extract_policy_map_block(config, policy_name)
      escaped = Regexp.escape(policy_name)
      m = config.match(/^policy-map #{escaped}\n(.*?)^!/m)
      m ? m[1] : nil
    end

    def format_mbps(value, unit)
      mbps = case unit
             when 'gbps' then value * 1000
             when 'mbps' then value
             when 'kbps' then value / 1000.0
             when 'bps'  then value / 1_000_000.0
             end
      # Round to a clean number: integers if whole, 1dp otherwise
      mbps == mbps.to_i.to_f ? "#{mbps.to_i} Mbps" : "#{'%.1f' % mbps} Mbps"
    end

    # ── HTTP ──────────────────────────────────────────────────────────────────

    def get(path)
      uri = URI("#{BASE}/#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = 5
      http.read_timeout = 15
      http.get(uri.request_uri).body
    end
  end
end
