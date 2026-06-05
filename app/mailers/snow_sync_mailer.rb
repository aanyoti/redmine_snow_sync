class SnowSyncMailer < ActionMailer::Base
  REDMINE_URL = 'https://projects-litzm.liquidtelecom.zm'.freeze

  def event_notification(recipient_email, event, issue, extra = {})
    @event      = event
    @issue      = issue
    @extra      = extra
    @issue_url  = "#{REDMINE_URL}/issues/#{issue.id}"
    @order_num  = issue.custom_field_value(IssueCustomField.find_by(name: 'Order Number')).to_s.presence || "##{issue.id}"

    mail(
      to:           recipient_email,
      from:         Setting.mail_from,
      subject:      email_subject,
      content_type: 'text/html'
    )
  end

  private

  def email_subject
    prefix = "[Redmine ##{@issue.id}]"
    case @event
    when 'new_import'    then "#{prefix} New Order Received — #{@issue.subject}"
    when 'sla_breach'    then "#{prefix} SLA Breach — #{@issue.subject}"
    when 'status_change' then "#{prefix} Status Update — #{@issue.subject}"
    when 'rejection'     then "#{prefix} Order Rejection Pending — #{@issue.subject}"
    when 'kam_not_found' then "#{prefix} Action Required: KAM Not Found in AD — #{@issue.subject}"
    else                      "#{prefix} Redmine Notification — #{@issue.subject}"
    end
  end
end
