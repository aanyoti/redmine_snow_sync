module SnowSync
  module ConnectionTest
    # Makes a minimal read-only call to verify credentials and permissions.
    # Returns { ok: bool, message: string, detail: string }
    def self.run(url:, username:, password:)
      client = SnowSync::Client.new(
        url:           url,
        username:      username,
        password:      password,
        field_account: 'u_account',
        field_order:   'u_order',
        field_service: 'u_service'
      )

      # Lightweight probe — fetch 1 record from sc_request with no filters
      records = client.send(:get, '/api/now/table/sc_request',
        sysparm_limit:         1,
        sysparm_fields:        'sys_id,number',
        sysparm_display_value: 'false',
        sysparm_no_count:      'true'
      )

      if records.is_a?(Array)
        if records.first
          num = records.first['number']
          num = num.is_a?(Hash) ? (num['display_value'] || num['value']) : num.to_s
          sample = " (sample record: #{num})"
        else
          sample = ' (connected — no records returned yet with current filters)'
        end
        { ok: true, message: "Connected successfully as #{username}.#{sample}" }
      else
        { ok: false, message: "Unexpected response format.", detail: records.inspect.first(200) }
      end

    rescue SnowSync::ApiError => e
      code = e.message[/^\d+/]
      msg  = case code
             when '401' then "Authentication failed — wrong username or password for account '#{username}'."
             when '403' then "Account '#{username}' authenticated but does not have permission to read sc_request."
             when '404' then "URL not found — check the instance URL."
             else            "API error: #{e.message}"
             end
      { ok: false, message: msg }
    rescue => e
      { ok: false, message: "Connection error: #{e.message}" }
    end
  end
end
