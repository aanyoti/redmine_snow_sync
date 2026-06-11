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

  def welcome_notification(recipient_email, user_name:, login:, password: nil, ldap: false)
    @user_name  = user_name
    @login      = login
    @password   = password
    @ldap       = ldap
    @portal_url = REDMINE_URL

    subject = ldap ? 'Liquid IT Projects Portal – Your Account' \
                   : 'Your Liquid IT Projects Portal – Login Credentials'

    mail(to: recipient_email, from: Setting.mail_from, subject: subject, content_type: 'text/html')
  end

  def procurement_closed_notification(recipient_email, contractor_name:, issue:, parent_issue:, po_number:, po_pdf: nil)
    @contractor_name = contractor_name
    @issue           = issue
    @parent_issue    = parent_issue
    @po_number       = po_number.presence || 'N/A'
    @portal_url      = REDMINE_URL

    if po_pdf && File.exist?(po_pdf.diskfile)
      attachments[po_pdf.filename] = File.read(po_pdf.diskfile, encoding: 'binary')
    end

    mail(
      to:           recipient_email,
      from:         Setting.mail_from,
      subject:      "Purchase Order #{@po_number} – #{parent_issue.subject}",
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
