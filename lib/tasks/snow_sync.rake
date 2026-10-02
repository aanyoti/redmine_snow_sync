namespace :redmine do
  namespace :snow_sync do
    desc 'Reconcile Organic issue statuses from SD WIP spreadsheet CSV'
    task reconcile_spreadsheet: :environment do
      require 'csv'

      STATUS_MAP = {
        'Field Work'   => 51,  # Fiber Build
        'Configs-LT'   => 59,  # Service Delivery
        'Under Trial'  => 52,  # Quality Assurance
        'signed-off'   => 60,  # Customer Handover (closest to Customer Sign-off)
        'On Hold-Cust' => 87,  # On Hold - Customer
        'On Hold-LT'   => 86,  # On Hold - Technical
        'On-Hold'      => 87,  # On Hold - Customer
        'Cancelled'    => 89,  # Closed - Rejected
      }.freeze

      csv_path = '/root/.claude/jobs/e3d7b410/tmp/wip_reconcile.csv'
      unless File.exist?(csv_path)
        puts "ERROR: CSV not found at #{csv_path}"
        exit 1
      end

      order_cf_id = IssueCustomField.find_by(name: 'Order Number')&.id
      unless order_cf_id
        puts 'ERROR: Order Number custom field not found'
        exit 1
      end

      system_user = User.where(admin: true).order(:id).first
      updated       = 0
      already_ok    = 0
      not_found_jul = []
      errors        = []

      CSV.foreach(csv_path, headers: true) do |row|
        order_num    = row['order_number'].to_s.strip
        sheet_status = row['sheet_status'].to_s.strip
        date_str     = row['date'].to_s.strip

        target_sid = STATUS_MAP[sheet_status]
        unless target_sid
          puts "  SKIP unknown status '#{sheet_status}' for #{order_num}"
          next
        end

        cv = CustomValue.where(custom_field_id: order_cf_id, value: order_num, customized_type: 'Issue').first
        unless cv
          date = Date.parse(date_str) rescue nil
          if date && date >= Date.new(2026, 7, 1)
            not_found_jul << { order: order_num, status: sheet_status, date: date_str }
          end
          next
        end

        issue = Issue.find_by(id: cv.customized_id, project_id: 5, tracker_id: 14)
        unless issue
          date = Date.parse(date_str) rescue nil
          if date && date >= Date.new(2026, 7, 1)
            not_found_jul << { order: order_num, status: sheet_status, date: date_str }
          end
          next
        end

        if issue.status_id == target_sid
          already_ok += 1
          next
        end

        old_sid  = issue.status_id
        old_name = issue.status.name
        new_name = IssueStatus.find_by(id: target_sid)&.name || target_sid.to_s

        begin
          Issue.transaction do
            issue.update_column(:status_id, target_sid)
            issue.update_column(:updated_on, Time.current)

            journal = issue.journals.build(
              user:  system_user,
              notes: "Status updated via SD WIP spreadsheet reconciliation (Aug 2026). Previous status: *#{old_name}*."
            )
            journal.details.build(
              property:  'attr',
              prop_key:  'status_id',
              old_value: old_sid.to_s,
              value:     target_sid.to_s
            )
            journal.save!
          end

          puts "  ##{issue.id} #{order_num}: #{old_name} → #{new_name} (#{sheet_status})"
          updated += 1
        rescue => e
          errors << "#{order_num}: #{e.message}"
          puts "  ERROR #{order_num}: #{e.message}"
        end
      end

      puts "\n=== RECONCILIATION COMPLETE ==="
      puts "  Updated:       #{updated}"
      puts "  Already OK:    #{already_ok}"
      puts "  Errors:        #{errors.size}"
      puts "  Not in Redmine (July 2026+): #{not_found_jul.size}"

      if not_found_jul.any?
        puts "\n=== MISSING FROM REDMINE (July 2026+) ==="
        not_found_jul.each { |r| puts "  #{r[:order]}  #{r[:date]}  (#{r[:status]})" }
      end
    end

    desc 'Create LT Opportunity Number CF and backfill from salesforce_orders for all tracker 14/18 issues'
    task backfill_lt_opp_number: :environment do
      # ── 1. Ensure CF exists ──────────────────────────────────────────────
      cf = IssueCustomField.find_or_initialize_by(name: 'LT Opportunity Number')
      if cf.new_record?
        cf.assign_attributes(
          field_format: 'string', is_required: false, is_for_all: false,
          searchable: true, editable: false, visible: true,
          tracker_ids: [14, 18]
        )
        cf.save!
        puts "  Created CF 'LT Opportunity Number' (id=#{cf.id})"
      else
        puts "  CF 'LT Opportunity Number' already exists (id=#{cf.id})"
        # Ensure trackers 14 and 18 are assigned
        cf.tracker_ids = (cf.tracker_ids + [14, 18]).uniq
        cf.save!
      end

      order_cf_id = IssueCustomField.find_by(name: 'Order Number')&.id
      unless order_cf_id
        puts "ERROR: 'Order Number' CF not found"; exit 1
      end

      # ── 2. Gather all tracker 14/18 issues with an order number ─────────
      issue_orders = CustomValue
        .joins("INNER JOIN issues ON issues.id = custom_values.customized_id")
        .where(custom_field_id: order_cf_id, customized_type: 'Issue')
        .where("custom_values.value != '' AND custom_values.value IS NOT NULL")
        .where("issues.project_id = 5 AND issues.tracker_id IN (14, 18)")
        .pluck(:customized_id, :value)
        .to_h

      puts "  Found #{issue_orders.size} issues to process"

      # ── 3. Batch-fetch lt_opp_number from salesforce_orders ──────────────
      order_nums   = issue_orders.values.uniq
      placeholders = order_nums.map { '?' }.join(',')
      sf_rows = ActiveRecord::Base.connection.execute(
        ActiveRecord::Base.sanitize_sql_array(
          ["SELECT DISTINCT ON (order_number) order_number, lt_opp_number
            FROM salesforce_orders WHERE order_number IN (#{placeholders})", *order_nums]
        )
      ).index_by { |r| r['order_number'] }

      puts "  Matched #{sf_rows.size} orders in Salesforce"

      # ── 4. Load existing CF values to avoid unnecessary writes ───────────
      issue_ids   = issue_orders.keys
      current_vals = CustomValue
        .where(customized_type: 'Issue', customized_id: issue_ids, custom_field_id: cf.id)
        .pluck(:customized_id, :value).to_h

      # ── 5. Upsert ────────────────────────────────────────────────────────
      updated = 0
      no_match = 0

      issue_orders.each do |issue_id, order_num|
        sf = sf_rows[order_num]
        unless sf
          no_match += 1
          next
        end

        opp_num = sf['lt_opp_number'].presence
        next unless opp_num
        next if current_vals[issue_id].to_s.strip == opp_num

        cv = CustomValue.find_or_initialize_by(
          customized_type: 'Issue', customized_id: issue_id, custom_field_id: cf.id
        )
        cv.value = opp_num
        cv.save!
        updated += 1
        puts "  ##{issue_id} (#{order_num}) → #{opp_num}" if updated <= 20
      end

      puts "  ..." if updated > 20
      puts "\n=== DONE ==="
      puts "  Updated:   #{updated}"
      puts "  No SF match: #{no_match}"
      puts "  Already correct / no SF opp number: #{issue_orders.size - updated - no_match}"
    end

    desc 'Pull new ServiceNow requests into Redmine'
    task run: :environment do
      puts "[#{Time.current}] SnowSync: starting..."
      result = SnowSync::Importer.new.run
      puts "[#{Time.current}] SnowSync: imported=#{result[:imported]} skipped=#{result[:skipped]} errors=#{result[:errors].size}"
      result[:errors].each { |e| puts "  ERROR: #{e}" }
    end

    desc 'DRY RUN: Test LDAP user creation, KAMs group, currency conversion — no changes saved'
    task test_new_features: :environment do
      require_relative '../snow_sync/ldap_user_finder'
      require_relative '../snow_sync/kam_group_manager'
      require_relative '../snow_sync/pdf_extractor'

      cfg  = Setting.plugin_redmine_snow_sync
      rate = cfg['zmw_usd_rate'].to_f
      rate = 27.50 if rate.zero?

      puts "\n#{'='*60}"
      puts "SnowSync dry-run test — no changes will be saved"
      puts "Exchange rate: 1 USD = #{rate} ZMW"
      puts "AD base: #{AuthSource.find(1).base_dn}"
      puts "="*60

      # ── 1. LDAP user lookup ─────────────────────────────────────
      puts "\n[ 1 ] LDAP user lookup"
      names = CustomValue.where(custom_field_id: IssueCustomField.find_by(name: 'Prepared By')&.id)
                         .pluck(:value).uniq.reject(&:blank?)
      names.each do |name|
        existing = User.active.find_by(
          firstname: name.split(' ', 2)[0],
          lastname:  name.split(' ', 2)[1]
        ) || User.find_by(login: name.split(' ', 2).join('.'))

        if existing
          puts "  #{name.ljust(22)} → already in Redmine as '#{existing.login}'"
          next
        end

        # Dry-run: call finder but wrap in transaction we roll back
        result = nil
        ActiveRecord::Base.transaction do
          result = SnowSync::LdapUserFinder.new.find_or_create(name)
          raise ActiveRecord::Rollback
        end

        if result
          puts "  #{name.ljust(22)} → WOULD CREATE: login=#{result.login} mail=#{result.mail} admin=#{result.admin}"
        else
          puts "  #{name.ljust(22)} → NOT FOUND in AD"
        end
      end

      # ── 2. KAMs group ──────────────────────────────────────────
      puts "\n[ 2 ] KAMs group"
      group = Group.find_by(lastname: 'KAMs')
      role  = Role.find_by(name: 'Key Account Manager')
      puts "  Role 'Key Account Manager': #{role ? "exists (id=#{role.id})" : 'MISSING'}"
      puts "  Group 'KAMs': #{group ? "exists (id=#{group.id}, #{group.users.count} members)" : 'will be created'}"
      mem = group && Member.find_by(project_id: 5, user_id: group.id)
      puts "  Project membership: #{mem ? 'already set' : 'will be added'}"

      # ── 3. Currency conversion ─────────────────────────────────
      puts "\n[ 3 ] Currency conversion (rate: 1 USD = #{rate} ZMW)"
      puts "  #{'Issue'.ljust(8)} #{'Currency'.ljust(10)} #{'NRR (native)'.ljust(15)} #{'NRR (converted)'.ljust(16)} #{'MRR (native)'.ljust(15)} MRR (converted)"
      puts "  " + "-"*86

      Issue.where(project_id: 5, tracker_id: 14).each do |issue|
        att = issue.attachments.detect { |a| a.filename =~ /CECLT.*Detailed.*\.pdf/i }
        next unless att

        data = SnowSync::PdfExtractor.extract(att.diskfile)
        next if data.empty?

        currency = data[:currency] || 'ZMW'
        nrr_raw  = data[:nrr].to_s.gsub(',', '').to_f
        mrr_raw  = data[:mrr].to_s.gsub(',', '').to_f

        if currency == 'ZMW'
          nrr_conv = format('%.2f', nrr_raw / rate)
          mrr_conv = format('%.2f', mrr_raw / rate)
          puts "  ##{issue.id.to_s.ljust(6)} #{'ZMW'.ljust(10)} #{data[:nrr].ljust(15)} #{"→ USD #{nrr_conv}".ljust(16)} #{data[:mrr].ljust(15)} → USD #{mrr_conv}"
        else
          nrr_conv = format('%.2f', nrr_raw * rate)
          mrr_conv = format('%.2f', mrr_raw * rate)
          puts "  ##{issue.id.to_s.ljust(6)} #{'USD'.ljust(10)} #{data[:nrr].ljust(15)} #{"→ ZMW #{nrr_conv}".ljust(16)} #{data[:mrr].ljust(15)} → ZMW #{mrr_conv}"
        end
      end

      puts "\n#{'='*60}"
      puts "Dry run complete. Run rake redmine:snow_sync:run to go live."
      puts "="*60
    end

    desc 'Daily SNow sync health check — alert if no successful run in last 25h or errors found'
    task snow_health_check: :environment do
      log_path = '/var/log/redmine_snow_sync.log'
      window   = 25.hours.ago

      unless File.exist?(log_path)
        puts "[#{Time.current}] SNOW HEALTH: log file not found"
        next
      end

      recent_lines = File.foreach(log_path).select do |line|
        m = line.match(/\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC)\]/)
        m && Time.parse(m[1]) >= window rescue false
      end

      last_run_line = recent_lines.select { |l| l.include?('imported=') }.last
      error_lines   = recent_lines.select { |l| l.strip.start_with?('ERROR:') }

      problems = []

      if last_run_line.nil?
        problems << "No sync run recorded in the last 25 hours (cron may have stopped)."
      end

      problems << "#{error_lines.size} error(s) recorded in the last 25 hours." if error_lines.any?

      if problems.any?
        msg = "SNow sync health check failed:\n" + problems.map { |p| "• #{p}" }.join("\n")
        puts "[#{Time.current}] SNOW HEALTH ALERT: #{msg}"
        error_lines.each { |e| puts "  #{e.strip}" }

        # Reuse the sfdc_staleness_alert mailer (same recipient/from already configured)
        full_msg = msg + (error_lines.any? ? "\n\nErrors:\n" + error_lines.map(&:strip).join("\n") : "") +
                   "\n\nRun: rake redmine:snow_sync:run[retroactive] to catch up on missing records."
        SnowSyncMailer.sfdc_staleness_alert("[SNow Sync] #{full_msg}").deliver_now
      else
        puts "[#{Time.current}] SNOW HEALTH OK — last run: #{last_run_line&.strip}"
      end
    end

    desc 'Alert if Salesforce sync has not run in the last 25 hours'
    task sfdc_staleness_check: :environment do
      last_sync = ActiveRecord::Base.connection
                    .select_value("SELECT MAX(synced_at) FROM salesforce_orders")
      last_sync = last_sync ? Time.parse(last_sync.to_s) : nil
      hours_ago = last_sync ? ((Time.current - last_sync) / 3600).round(1) : nil

      if last_sync.nil? || (Time.current - last_sync) > 25.hours
        msg = last_sync \
          ? "Salesforce sync is stale — last run #{hours_ago}h ago (#{last_sync.strftime('%Y-%m-%d %H:%M UTC')})." \
          : "Salesforce sync has never run — salesforce_orders table is empty."

        puts "[#{Time.current}] SFDC STALENESS: #{msg}"

        SnowSyncMailer.sfdc_staleness_alert(msg).deliver_now
      else
        puts "[#{Time.current}] SFDC staleness OK — last sync #{hours_ago}h ago"
      end
    end

    desc 'Send 3x-daily Organic order status digest email'
    task status_digest: :environment do
      # Production recipients — everyone in litzm-techinical@liquid.tech
      production_list = ['litzm-technical@liquid.tech']
      # Test override: set TEST_DIGEST_EMAIL=anthony.anyoti@liquid.tech to send only there
      recipients = if ENV['TEST_DIGEST_EMAIL'].present?
                     [ENV['TEST_DIGEST_EMAIL']]
                   else
                     production_list
                   end

      puts "[#{Time.current}] SnowDigest: sending to #{recipients.join(', ')}..."
      recipients.each do |email|
        SnowDigestMailer.status_digest(email).deliver_now
        puts "[#{Time.current}] SnowDigest: sent to #{email}"
      end
    end

    desc 'Check SLA timers and send breach notifications'
    task sla_check: :environment do
      puts "[#{Time.current}] SnowSLA: checking breaches..."
      SnowSlaTimer.check_breaches
      puts "[#{Time.current}] SnowSLA: done"
    end

    desc 'Backfill PDF data (Account Number, Prepared By, NRR, MRR) for existing Fiber Orders issues'
    task backfill_pdf: :environment do
      require_relative '../snow_sync/pdf_extractor'

      cf = ->(name) { IssueCustomField.find_by(name: name)&.id&.to_s }

      issues = Issue.where(project_id: 5, tracker_id: 14)
      puts "Processing #{issues.count} issues..."
      updated = 0
      skipped = 0

      issues.each do |issue|
        att = issue.attachments.detect { |a| a.filename =~ /CECLT.*Detailed.*\.pdf/i }
        unless att
          skipped += 1
          next
        end

        data = SnowSync::PdfExtractor.extract(att.diskfile)
        if data.empty?
          skipped += 1
          next
        end

        updates = {
          cf.('Account Number') => data[:account_number],
          cf.('Prepared By')    => data[:prepared_by],
          cf.('NRR (ZMW)')      => data[:nrr],
          cf.('MRR (ZMW)')      => data[:mrr]
        }.reject { |k, v| k.nil? || v.nil? }

        if updates.any?
          issue.custom_field_values = updates
          issue.save(validate: false)
          puts "  ##{issue.id} #{issue.subject[0..50]}: NRR=#{data[:nrr]} MRR=#{data[:mrr]} by #{data[:prepared_by]}"
          updated += 1
        else
          skipped += 1
        end
      end

      puts "Done. Updated: #{updated}  Skipped (no PDF): #{skipped}"
    end
  end
end
