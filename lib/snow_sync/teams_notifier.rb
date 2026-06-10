require 'net/http'
require 'json'
require 'uri'

module SnowSync
  class TeamsNotifier
    REDMINE_URL      = 'https://projects-litzm.liquidtelecom.zm'.freeze
    CONTRACTOR_ROLE  = 20

    def self.notify(event, issue, extra = {})
      new.send_notification(event, issue, extra)
    end

    def send_notification(event, issue, extra = {})
      cfg = Setting.plugin_redmine_snow_sync

      # If test_email is set, send only there (dev/test override)
      test_email = cfg['teams_test_email'].to_s.strip.presence
      if test_email.present?
        SnowSyncMailer.event_notification(test_email, event, issue, extra).deliver_now
        Rails.logger.info "SnowSync Email [test]: sent '#{event}' to #{test_email} for issue ##{issue.id}"
      else
        emails = build_recipients(event, issue)
        emails.each do |addr|
          SnowSyncMailer.event_notification(addr, event, issue, extra).deliver_now
        end
        Rails.logger.info "SnowSync Email: sent '#{event}' for issue ##{issue.id} to #{emails.join(', ')}" if emails.any?
      end

      # Teams webhook
      url = cfg['teams_webhook_url'].to_s.strip
      return unless url.present?
      post(url, build_payload(event, issue, extra))
      Rails.logger.info "SnowSync Teams: sent '#{event}' notification for issue ##{issue.id}"
    rescue => e
      Rails.logger.error "SnowSync Teams/Email: failed for issue ##{issue.id}: #{e.message}"
    end

    private

    # ── Recipient rules ──────────────────────────────────────────────────────
    #
    # new_import    → KAM (Prepared By) + assignee + Commercial Leads
    # status_change → assignee + KAM + issue watchers
    # rejection     → KAM + assignee + Commercial Leads
    # kam_not_found → admins + Commercial Leads
    # sla_breach    → assignee + issue watchers + Commercial Leads
    #
    # Contractor rule: contractor-only users receive ONLY if assigned to them.

    def build_recipients(event, issue)
      assignee  = issue.assigned_to.is_a?(User) ? issue.assigned_to : nil
      kam_user  = find_kam(issue)
      watchers  = issue.watcher_users.select { |u| u.is_a?(User) && u.active? }
      com_leads = commercial_leads
      admins    = User.active.where(admin: true).to_a

      users = case event
              when 'new_import'
                [assignee, kam_user].compact + com_leads + admins
              when 'status_change'
                [assignee, kam_user].compact + watchers + admins
              when 'rejection'
                [assignee, kam_user].compact + com_leads + admins
              when 'kam_not_found'
                admins + com_leads
              when 'sla_breach'
                [assignee].compact + watchers + com_leads + admins
              else
                [assignee].compact + admins
              end

      users.uniq.select { |u| should_notify?(u, issue) }
           .map { |u| u.email_address&.address }
           .compact.uniq
    end

    # Contractor-only users receive only if the issue is assigned to them.
    def should_notify?(user, issue)
      return false unless user.active?
      role_ids = user.memberships.flat_map(&:role_ids).uniq
      is_contractor_only = role_ids.include?(CONTRACTOR_ROLE) && (role_ids - [CONTRACTOR_ROLE]).empty?
      !is_contractor_only || issue.assigned_to_id == user.id
    end

    def find_kam(issue)
      cf = IssueCustomField.find_by(name: 'Prepared By')
      return nil unless cf
      name = issue.custom_field_value(cf.id).to_s.strip
      return nil if name.blank?
      User.active.find { |u| u.name.casecmp?(name) }
    end

    def commercial_leads
      User.active
          .joins(members: :roles)
          .where(roles: { name: 'Commercial Lead' })
          .distinct
          .to_a
    end

    # ── Teams webhook payload ────────────────────────────────────────────────

    def build_payload(event, issue, extra)
      cf        = ->(name) { IssueCustomField.find_by(name: name)&.id&.to_s }
      assignee  = issue.assigned_to
      {
        event:          event,
        issue_id:       issue.id,
        issue_subject:  issue.subject,
        issue_url:      "#{REDMINE_URL}/issues/#{issue.id}",
        tracker:        issue.tracker.name,
        status:         issue.status.name,
        project:        issue.project.name,
        order_number:   issue.custom_field_value(cf.('Order Number')).to_s.presence,
        account:        issue.custom_field_value(cf.('Account')).to_s.presence,
        assignee_name:  assignee&.name,
        assignee_email: assignee&.mail,
        kam_name:       issue.custom_field_value(cf.('Prepared By')).to_s.presence,
      }.merge(extra).compact
    end

    def post(url, payload)
      uri              = URI(url)
      http             = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl     = uri.scheme == 'https'
      http.read_timeout = 15
      http.open_timeout = 10
      req              = Net::HTTP::Post.new(uri)
      req['Content-Type'] = 'application/json'
      req.body         = payload.to_json
      http.request(req)
    end
  end
end
