class SnowSlaMailer < Mailer
  def breach_notification(user, issue, status_name, elapsed, target)
    @user        = user
    @issue       = issue
    @status_name = status_name
    @elapsed     = elapsed
    @target      = target
    @issue_url   = url_for(controller: 'issues', action: 'show', id: issue.id)

    mail(
      to:      user.mail,
      subject: "[SLA Breach] ##{issue.id} — #{issue.subject.first(60)} (#{status_name})"
    )
  end
end
