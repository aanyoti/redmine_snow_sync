require 'net/http'
require 'json'
require 'uri'

module SnowSync
  class TeamsNotifier
    REDMINE_URL = 'https://projects-litzm.liquidtelecom.zm'.freeze

    def self.notify(event, issue, extra = {})
      new.send_notification(event, issue, extra)
    end

    def send_notification(event, issue, extra = {})
      url = Setting.plugin_redmine_snow_sync['teams_webhook_url'].to_s.strip
      return unless url.present?

      payload = build_payload(event, issue, extra)
      post(url, payload)
      Rails.logger.info "SnowSync Teams: sent '#{event}' notification for issue ##{issue.id}"
    rescue => e
      Rails.logger.error "SnowSync Teams: failed for issue ##{issue.id}: #{e.message}"
    end

    private

    def build_payload(event, issue, extra)
      cf        = ->(name) { IssueCustomField.find_by(name: name)&.id&.to_s }
      assignee  = issue.assigned_to
      kam_name  = issue.custom_field_value(cf.('Prepared By')).to_s.presence
      order_num = issue.custom_field_value(cf.('Order Number')).to_s.presence
      account   = issue.custom_field_value(cf.('Account')).to_s.presence

      {
        event:           event,
        issue_id:        issue.id,
        issue_subject:   issue.subject,
        issue_url:       "#{REDMINE_URL}/issues/#{issue.id}",
        tracker:         issue.tracker.name,
        status:          issue.status.name,
        project:         issue.project.name,
        order_number:    order_num,
        account:         account,
        assignee_name:   assignee&.name,
        assignee_email:  assignee&.mail,
        kam_name:        kam_name,
      }.merge(extra).compact
    end

    def post(url, payload)
      uri        = URI(url)
      http       = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = uri.scheme == 'https'
      http.read_timeout = 15
      http.open_timeout = 10

      req = Net::HTTP::Post.new(uri)
      req['Content-Type'] = 'application/json'
      req.body = payload.to_json
      http.request(req)
    end
  end
end
