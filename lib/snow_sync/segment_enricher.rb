module SnowSync
  class SegmentEnricher
    COMMERCIAL_ORDERS_TRACKER_ID = 14

    def initialize
      @cfg = Setting.plugin_redmine_snow_sync
      @log = Rails.logger
    end

    def process(records)
      results = { processed: 0, updated: 0, not_found: 0, flagged: 0 }

      records.each do |rec|
        results[:processed] += 1
        issues = find_issues(rec)

        if issues.empty?
          @log.warn "SnowSync Webhook: no issue found for order='#{rec['order_number']}' account='#{rec['account_name']}'"
          results[:not_found] += 1
          next
        end

        issues.each do |issue|
          outcome = enrich(issue, rec)
          results[:updated] += 1 if outcome
          results[:flagged] += 1 if outcome == :flagged
        end
      end

      results
    end

    private

    def find_issues(rec)
      order_num = rec['order_number'].to_s.strip
      account   = rec['account_name'].to_s.strip

      # Primary: order number is exact — use CF 55 (Order Number)
      if order_num.present?
        ids = CustomValue.where(custom_field_id: 55, value: order_num).pluck(:customized_id)
        issues = Issue.where(id: ids, tracker_id: COMMERCIAL_ORDERS_TRACKER_ID).to_a
        return issues if issues.any?
      end

      # Fallback: account name — may match multiple orders for same customer
      if account.present?
        ids = CustomValue.where(custom_field_id: 72, value: account).pluck(:customized_id)
        return Issue.where(id: ids, tracker_id: COMMERCIAL_ORDERS_TRACKER_ID).to_a
      end

      []
    end

    def enrich(issue, rec)
      segment      = rec['segment'].to_s.strip
      opp_type     = rec['opportunity_type'].to_s.strip
      sf_account   = rec['account_name'].to_s.strip

      opp_cf           = IssueCustomField.find_by(name: 'Opportunity Type')
      account_cf       = IssueCustomField.find_by(name: 'Account')
      current_opp_type = opp_cf ? issue.custom_field_value(opp_cf.id).to_s.strip : ''
      category         = IssueCategory.find_by(project_id: issue.project_id, name: "Segment - #{segment}")

      flagged = false

      # Always update category if it exists and has changed
      issue.category = category if category && issue.category_id != category.id

      # Prefer Salesforce account name over SNow company name — SF is the source of truth for billing names
      if account_cf && sf_account.present?
        current_account = issue.custom_field_value(account_cf.id).to_s.strip
        if current_account != sf_account
          issue.custom_field_values = issue.custom_field_values.merge(account_cf.id.to_s => sf_account)
        end
      end

      if current_opp_type.blank?
        # First sync — set opportunity type and reassign tracker if mapped
        if opp_cf && opp_type.present?
          issue.custom_field_values = { opp_cf.id.to_s => opp_type }
        end
        new_tracker_id = tracker_for(opp_type)
        if new_tracker_id && new_tracker_id != issue.tracker_id
          issue.tracker_id = new_tracker_id
        end

      elsif opp_type.present? && current_opp_type != opp_type
        # Opportunity Type changed in Salesforce — journal note, leave tracker alone
        actor = User.where(admin: true).first || User.active.first
        issue.init_journal(actor,
          "Salesforce sync: Opportunity Type changed from '#{current_opp_type}' to '#{opp_type}'. " \
          "Review whether the tracker needs updating."
        )
        flagged = true
      end

      if issue.save
        @log.info "SnowSync Webhook: enriched issue ##{issue.id} — segment=#{segment}, opp_type=#{opp_type}"
        flagged ? :flagged : true
      else
        @log.warn "SnowSync Webhook: could not save issue ##{issue.id}: #{issue.errors.full_messages.join(', ')}"
        false
      end
    rescue => e
      @log.warn "SnowSync Webhook: error on issue ##{issue.id}: #{e.message}"
      false
    end

    def tracker_for(opp_type)
      return nil if opp_type.blank?
      @cfg['opportunity_tracker_map'].to_s.split(',').each do |pair|
        key, val = pair.strip.split(':').map(&:strip)
        return val.to_i if key&.casecmp?(opp_type)
      end
      nil
    end
  end
end
