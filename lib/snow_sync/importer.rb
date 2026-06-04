module SnowSync
  class Importer
    attr_reader :imported, :skipped, :errors

    def initialize
      @cfg      = Setting.plugin_redmine_snow_sync
      @log      = Rails.logger
      @imported = 0
      @skipped  = 0
      @errors   = []
      @cf_map   = {}
    end

    def run
      unless configured?
        return { imported: 0, skipped: 0, errors: ['Plugin not fully configured — check username, password, project and tracker.'] }
      end

      client          = build_client
      groups          = @cfg['assignment_groups'].split(',').map(&:strip).reject(&:blank?)
      states          = @cfg['poll_states'].to_s.split(',').map(&:strip).reject(&:blank?)
      delivery_stages = @cfg['poll_delivery_stage'].to_s.split(',').map(&:strip).reject(&:blank?)
      days_back       = @cfg['days_back'].to_i

      since = if days_back > 0
                days_back.days.ago
              elsif @cfg['last_sync_at'].present?
                Time.parse(@cfg['last_sync_at'])
              end

      offset = 0
      limit  = 100

      @log.info "SnowSync: querying since #{since&.iso8601 || 'all time (first run)'}"

      loop do
        records = client.fetch_requests(
          groups: groups, states: states, delivery_stages: delivery_stages,
          since: since, offset: offset, limit: limit
        )
        break if records.blank?

        records.each { |rec| process(rec, client) }

        break if records.size < limit
        offset += limit
      end

      Setting.plugin_redmine_snow_sync = @cfg.merge('last_sync_at' => Time.current.iso8601)

      { imported: @imported, skipped: @skipped, errors: @errors }
    rescue SnowSync::ApiError => e
      { imported: @imported, skipped: @skipped, errors: ["ServiceNow API error: #{e.message}"] }
    end

    private

    # ── Per-record processing ─────────────────────────────────────────────

    def process(rec, client)
      sys_id = raw(rec, 'sys_id')
      number = disp(rec, 'number')

      if SnowSyncRecord.synced?(sys_id)
        @skipped += 1
        return
      end

      # Check if an issue already exists for this order number (consolidation)
      order_number   = disp(rec, @cfg['field_order']).to_s.strip
      existing_issue = find_existing_by_order(order_number) if order_number.present?

      if existing_issue
        attach_files(rec, existing_issue, client)
        append_service_component(existing_issue, rec)
        SnowSyncRecord.create!(
          snow_sys_id: sys_id,
          snow_number: number,
          issue_id:    existing_issue.id,
          sync_status: 'ok',
          synced_at:   Time.current
        )
        @imported += 1
        @log.info "SnowSync: #{number} consolidated into existing issue ##{existing_issue.id} (order #{order_number})"
      else
        issue = build_issue(rec)
        if issue.save
          attach_files(rec, issue, client)
          enrich_from_pdf(issue)
          SnowSyncRecord.create!(
            snow_sys_id: sys_id,
            snow_number: number,
            issue_id:    issue.id,
            sync_status: 'ok',
            synced_at:   Time.current
          )
          @imported += 1
          @log.info "SnowSync: imported #{number} → Redmine issue ##{issue.id}"
        else
          msg = "#{number}: #{issue.errors.full_messages.join(', ')}"
          @errors << msg
          @log.error "SnowSync: failed to save issue for #{msg}"
          SnowSyncRecord.create!(
            snow_sys_id: sys_id,
            snow_number: number,
            sync_status: 'error',
            sync_error:  issue.errors.full_messages.join(', '),
            synced_at:   Time.current
          )
        end
      end
    rescue => e
      number = disp(rec, 'number') rescue '?'
      @errors << "#{number}: #{e.message}"
      @log.error "SnowSync: exception on #{number}: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
    end

    # ── Issue builder ─────────────────────────────────────────────────────

    def build_issue(rec)
      project = Project.find(@cfg['target_project_id'].to_i)
      author  = User.where(admin: true).first || User.active.first

      # Classify tracker and service type from subject/description
      subject     = build_subject(rec)
      description = build_description(rec)
      result      = SnowSync::TrackerClassifier.classify_issue(subject, description)

      tracker = if result && result[:tracker]
                  result[:tracker]
                else
                  Tracker.find(@cfg['target_tracker_id'].to_i)
                end

      issue = Issue.new(
        project:     project,
        tracker:     tracker,
        author:      author,
        subject:     subject,
        description: description,
        due_date:    parse_date(raw(rec, 'due_date'))
      )

      cf_vals = build_cf_values(rec)

      # Set Service Type if C2
      if result && result[:service_type]
        service_type_cf_id = cf('Service Type')
        cf_vals[service_type_cf_id] = result[:service_type] if service_type_cf_id
      end

      # Initialise Services field with this first component
      services_cf_id = cf('Services')
      if services_cf_id && tracker == result&.dig(:tracker)
        cf_vals[services_cf_id] = subject
      end

      cf_vals = cf_vals.compact

      # Warn if any CF value will be silently dropped (not available for this tracker+project)
      available_ids = issue.available_custom_fields.map { |cf| cf.id.to_s }.to_set
      cf_vals.each_key do |key|
        unless available_ids.include?(key.to_s)
          @log.warn "SnowSync: CF id=#{key} not available on tracker '#{tracker.name}' — value will be dropped. Check CF tracker/project associations."
        end
      end

      issue.custom_field_values = cf_vals
      issue
    end

    # ── Order consolidation helpers ───────────────────────────────────────

    def find_existing_by_order(order_number)
      cf_id = IssueCustomField.find_by(name: 'Order Number')&.id
      return nil unless cf_id
      cv = CustomValue.where(custom_field_id: cf_id, value: order_number).first
      return nil unless cv
      Issue.find_by(id: cv.customized_id)
    end

    def append_service_component(issue, rec)
      issue.reload
      component = build_subject(rec)
      number    = disp(rec, 'number')

      # Append to Services CF
      services_cf_id = cf('Services')
      if services_cf_id
        current  = issue.custom_field_value(services_cf_id).to_s.strip
        new_line = "#{component} (#{number})"
        updated  = current.blank? ? new_line : "#{current}\n#{new_line}"
        issue.custom_field_values = { services_cf_id => updated }
        issue.save(validate: false)
      end

      # Add journal note
      sys_id   = raw(rec, 'sys_id')
      snow_url = "#{@cfg['snow_url']}/sc_request.do?sys_id=#{sys_id}"
      journal  = issue.journals.build(user: User.where(admin: true).first || User.active.first)
      journal.notes = "Additional SNow request linked: \"#{number}\":#{snow_url}\nComponent: #{component}"
      journal.save
      @log.info "SnowSync: appended component '#{component}' to issue ##{issue.id}"
    rescue => e
      @log.warn "SnowSync: append_service_component failed on issue ##{issue.id}: #{e.message}"
    end

    # ── Subject builder ───────────────────────────────────────────────────

    def build_subject(rec)
      company  = extract_company(rec)
      category = extract_category(disp(rec, 'short_description'))
      service  = disp(rec, @cfg['field_service']).to_s.sub('-', ' ').strip

      [company, category, service].select(&:present?).join(' - ')
        .presence || disp(rec, 'short_description').presence || "(no subject)"
    end

    def extract_company(rec)
      company = disp(rec, 'company').presence
      return company if company.present?
      desc  = disp(rec, 'description').to_s
      match = desc.match(/being delivered for\s+(.+?)(?:\s*\n|$)/i)
      match ? match[1].strip : nil
    end

    def extract_category(short_desc)
      match = short_desc.to_s.match(/\s*-\s*(.+?)\s+with\s+reference\s+/i)
      match ? match[1].strip : short_desc.to_s.first(100)
    end

    def build_description(rec)
      body     = disp(rec, 'description').to_s.strip
      number   = disp(rec, 'number')
      sys_id   = raw(rec, 'sys_id')
      snow_url = "#{@cfg['snow_url']}/sc_request.do?sys_id=#{sys_id}"
      footer   = "_Synced from ServiceNow \"#{number}\":#{snow_url} on #{Time.current.strftime('%Y-%m-%d %H:%M %Z')}_"
      [body, "\n\n---\n#{footer}"].join
    end

    def build_cf_values(rec)
      account = disp(rec, 'company').presence ||
                disp(rec, @cfg['field_account']).presence ||
                extract_company(rec)
      {
        cf('SNow Request #')         => disp(rec, 'number'),
        cf('Account')                => account,
        cf('Requested For')          => disp(rec, 'requested_for'),
        cf('Order')                  => disp(rec, @cfg['field_order']),
        cf('Service')                => disp(rec, @cfg['field_service']),
        cf('SNow Opened')            => parse_date(raw(rec, 'opened_at')),
        cf('Assignment Group')       => disp(rec, 'assignment_group'),
        cf('Request State')          => disp(rec, 'state'),
        cf('Service Delivery Stage') => disp(rec, 'u_service_delivery_stage'),
        cf('SNow Sys ID')            => raw(rec, 'sys_id'),
        '55'                         => disp(rec, @cfg['field_order']),
        '57'                         => disp(rec, 'number'),
      }
    end

    # ── PDF enrichment ───────────────────────────────────────────────────

    def enrich_from_pdf(issue)
      issue.reload
      att = issue.attachments.detect { |a| a.filename =~ /CECLT.*Detailed.*\.pdf/i }
      return unless att

      data = SnowSync::PdfExtractor.extract(att.diskfile)
      return if data.empty?

      rate     = @cfg['zmw_usd_rate'].to_f
      rate     = 27.50 if rate.zero?
      currency = data[:currency] || 'ZMW'
      nrr_raw  = data[:nrr].to_s.gsub(',', '').to_f
      mrr_raw  = data[:mrr].to_s.gsub(',', '').to_f

      if currency == 'ZMW'
        nrr_zmw = data[:nrr]
        mrr_zmw = data[:mrr]
        nrr_usd = format('%.2f', nrr_raw / rate)
        mrr_usd = format('%.2f', mrr_raw / rate)
      else
        nrr_usd = data[:nrr]
        mrr_usd = data[:mrr]
        nrr_zmw = format('%.2f', nrr_raw * rate)
        mrr_zmw = format('%.2f', mrr_raw * rate)
      end

      updates = {
        cf('Account Number') => data[:account_number],
        cf('Prepared By')    => data[:prepared_by],
        cf('NRR (ZMW)')      => nrr_zmw,
        cf('MRR (ZMW)')      => mrr_zmw,
        cf('NRR (USD)')      => nrr_usd,
        cf('MRR (USD)')      => mrr_usd,
      }.reject { |k, v| k.nil? || v.nil? }

      issue.custom_field_values = updates
      issue.save(validate: false)
      @log.info "SnowSync: PDF enriched issue ##{issue.id} — #{currency} NRR=#{data[:nrr]} MRR=#{data[:mrr]}"

      return unless data[:prepared_by].present?

      kam = SnowSync::LdapUserFinder.find_or_create(data[:prepared_by])
      return unless kam

      SnowSync::KamGroupManager.ensure_member(kam)
      Watcher.where(watchable: issue, user: kam).first_or_create!
      @log.info "SnowSync: #{data[:prepared_by]} (#{kam.login}) added as watcher on issue ##{issue.id}"
    rescue => e
      @log.warn "SnowSync: PDF enrichment failed for issue ##{issue.id}: #{e.message}\n#{e.backtrace.first(2).join("\n")}"
    end

    # ── Attachments ───────────────────────────────────────────────────────

    def attach_files(rec, issue, client)
      sys_id      = raw(rec, 'sys_id')
      attachments = client.fetch_attachments(sys_id)
      return if attachments.blank?

      attachments.each do |att|
        att_sys_id   = att['sys_id']
        filename     = att['file_name'] || att.dig('file_name', 'value') || 'attachment'
        content_type = att['content_type'] || att.dig('content_type', 'value') || 'application/octet-stream'

        file_data = client.download_attachment(att_sys_id)

        Tempfile.create(['snow_att', File.extname(filename)]) do |tmp|
          tmp.binmode
          tmp.write(file_data[:body])
          tmp.rewind

          uploaded = ActionDispatch::Http::UploadedFile.new(
            tempfile: tmp,
            filename: filename,
            type:     file_data[:content_type].presence || content_type
          )

          attachment = Attachment.new(file: uploaded, author: issue.author, content_type: content_type)
          attachment.container = issue

          if attachment.save
            @log.info "SnowSync: attached #{filename} to issue ##{issue.id}"
          else
            @log.warn "SnowSync: could not save attachment #{filename}: #{attachment.errors.full_messages.join(', ')}"
          end
        end
      end
    rescue => e
      @log.warn "SnowSync: attachment sync failed for issue ##{issue.id}: #{e.message}"
    end

    # ── Helpers ───────────────────────────────────────────────────────────

    def configured?
      %w[snow_username snow_password target_project_id target_tracker_id].all? do |k|
        @cfg[k].present?
      end
    end

    def build_client
      SnowSync::Client.new(
        url:           @cfg['snow_url'],
        username:      @cfg['snow_username'],
        password:      @cfg['snow_password'],
        field_account: @cfg['field_account'],
        field_order:   @cfg['field_order'],
        field_service: @cfg['field_service']
      )
    end

    def disp(rec, field)
      v = rec[field]
      return '' if v.nil?
      v.is_a?(Hash) ? (v['display_value'].presence || v['value']).to_s : v.to_s
    end

    def raw(rec, field)
      v = rec[field]
      v.is_a?(Hash) ? v['value'].to_s : v.to_s
    end

    def parse_date(str)
      return nil if str.blank?
      Date.parse(str.split(' ').first) rescue nil
    end

    def cf(name)
      @cf_map[name] ||= IssueCustomField.find_by(name: name)&.id&.to_s
    end
  end
end
