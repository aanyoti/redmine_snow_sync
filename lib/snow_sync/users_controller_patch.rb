module SnowSync
  module UsersControllerPatch
    def create
      # Capture plain-text password before it gets hashed
      plain_password = params[:user]&.dig(:password).to_s.presence
      super
      # Only send if user was actually created
      return unless @user&.persisted?
      email = @user.email_address&.address
      return if email.blank?
      is_ldap = @user.auth_source_id.present?
      SnowSyncMailer.welcome_notification(
        email,
        user_name: @user.name,
        login:     @user.login,
        password:  is_ldap ? nil : plain_password,
        ldap:      is_ldap
      ).deliver_now
      Rails.logger.info "SnowSync: welcome email sent to #{email} for new user #{@user.login}"
    rescue => e
      Rails.logger.error "SnowSync: welcome email failed for #{@user&.login}: #{e.message}"
    end
  end
end
