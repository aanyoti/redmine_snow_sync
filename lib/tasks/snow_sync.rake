namespace :redmine do
  namespace :snow_sync do
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
