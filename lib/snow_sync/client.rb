require 'net/http'
require 'json'
require 'uri'
require 'openssl'

module SnowSync
  class Client
    CORE_FIELDS = %w[
      sys_id number short_description description
      requested_for due_date opened_at company
      assignment_group state u_service_delivery_stage
    ].freeze

    def initialize(url:, username:, password:, field_account:, field_order:, field_service:)
      @base_url      = url.chomp('/')
      @username      = username
      @password      = password
      @extra_fields  = [field_account, field_order, field_service].compact.uniq
    end

    def fetch_requests(groups:, states:, delivery_stages: [], since: nil, offset: 0, limit: 100)
      group_clause = "assignment_group.nameIN#{groups.join(',')}"
      state_clause = states.any? ? "stateIN#{states.join(',')}" : nil
      sds_clause   = delivery_stages.any? ? "u_service_delivery_stageIN#{delivery_stages.join(',')}" : nil
      date_clause  = since ? "sys_created_on>=#{since.strftime('%Y-%m-%d %H:%M:%S')}" : nil
      query        = [group_clause, state_clause, sds_clause, date_clause].compact.join('^') + '^ORDERBYsys_created_on'
      fields       = (CORE_FIELDS + @extra_fields).uniq.join(',')

      get('/api/now/table/sc_request',
          sysparm_query:         query,
          sysparm_fields:        fields,
          sysparm_display_value: 'all',
          sysparm_no_count:      'true',
          sysparm_limit:         limit,
          sysparm_offset:        offset)
    end

    def fetch_by_sys_id(sys_id)
      fields = (CORE_FIELDS + @extra_fields).uniq.join(',')
      result = get("/api/now/table/sc_request/#{sys_id}",
                   sysparm_fields:        fields,
                   sysparm_display_value: 'all')
      result.is_a?(Array) ? result.first : result
    end

    def fetch_attachments(table_sys_id)
      get('/api/now/attachment',
          sysparm_query: "table_name=sc_request^table_sys_id=#{table_sys_id}")
    end

    # Returns { body:, content_type:, filename: }
    def download_attachment(attachment_sys_id)
      get_binary("/api/now/attachment/#{attachment_sys_id}/file")
    end

    private

    def get(path, params = {})
      uri       = build_uri(path, params)
      req       = Net::HTTP::Get.new(uri)
      req['Accept']       = 'application/json'
      req['Content-Type'] = 'application/json'
      req.basic_auth(@username, @password)

      res = http(uri).request(req)
      raise ApiError, "#{res.code} #{res.message}: #{res.body.first(200)}" unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(res.body)['result'] || []
    end

    def get_binary(path)
      uri = build_uri(path)
      req = Net::HTTP::Get.new(uri)
      req.basic_auth(@username, @password)

      res = http(uri).request(req)
      raise ApiError, "Attachment #{res.code}: #{res.message}" unless res.is_a?(Net::HTTPSuccess)

      {
        body:         res.body,
        content_type: res['Content-Type'].to_s.split(';').first.strip,
        filename:     extract_filename(res)
      }
    end

    def build_uri(path, params = {})
      uri       = URI("#{@base_url}#{path}")
      uri.query = URI.encode_www_form(params) if params.any?
      uri
    end

    def http(uri)
      h              = Net::HTTP.new(uri.host, uri.port)
      h.use_ssl      = uri.scheme == 'https'
      h.verify_mode  = OpenSSL::SSL::VERIFY_PEER
      h.read_timeout = 60
      h.open_timeout = 15
      h
    end

    def extract_filename(res)
      cd = res['Content-Disposition'].to_s
      cd[/filename="?([^";\n]+)"?/, 1] || 'attachment'
    end
  end

  class ApiError < StandardError; end
end
