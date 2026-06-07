require 'net/ldap'

module SnowSync
  class LdapUserFinder
    AUTH_SOURCE_ID = 1

    def self.find_or_create(display_name)
      new.find_or_create(display_name)
    end

    def find_or_create(display_name)
      return nil if display_name.blank?

      parts = display_name.strip.split(' ', 2)
      return nil if parts.size < 2

      # Already in Redmine? Try exact name first, then first-name-only (handles surname changes)
      user = User.active.find_by(firstname: parts[0], lastname: parts[1])
      return user if user

      first_name_matches = User.active.where(firstname: parts[0]).to_a
      if first_name_matches.size == 1
        Rails.logger.info "SnowSync: matched '#{display_name}' to #{first_name_matches.first.login} by first name (surname differs)"
        return first_name_matches.first
      end

      # Query AD
      entry = ldap_lookup(display_name, parts)
      return nil unless entry

      login     = entry[:samaccountname].first.to_s.strip
      firstname = entry[:givenname].first.to_s.strip
      lastname  = entry[:sn].first.to_s.strip
      mail      = entry[:mail].first.to_s.strip

      # Already exists under their AD login?
      user = User.find_by(login: login)
      return user if user

      user = User.new(
        login:          login,
        firstname:      firstname,
        lastname:       lastname,
        mail:           mail,
        auth_source_id: AUTH_SOURCE_ID,
        admin:          false,
        status:         User::STATUS_ACTIVE
      )

      if user.save
        Rails.logger.info "SnowSync: created user '#{login}' (#{firstname} #{lastname}) from AD"
        Mailer.deliver_account_activated(user) rescue nil
        user
      else
        Rails.logger.warn "SnowSync: could not create user '#{display_name}': #{user.errors.full_messages.join(', ')}"
        nil
      end
    rescue => e
      Rails.logger.warn "SnowSync: LdapUserFinder error for '#{display_name}': #{e.message}"
      nil
    end

    private

    def auth_source
      @auth_source ||= AuthSource.find(AUTH_SOURCE_ID)
    end

    def ldap_lookup(display_name, parts)
      ldap = Net::LDAP.new(
        host: auth_source.host,
        port: auth_source.port,
        auth: { method: :simple, username: auth_source.account, password: auth_source.account_password }
      )

      attrs = %w[sAMAccountName givenName sn mail displayName]

      # Try displayName first (most reliable)
      results = ldap.search(
        base:       auth_source.base_dn,
        filter:     Net::LDAP::Filter.eq('displayName', display_name),
        attributes: attrs
      )
      return results.first if results&.any?

      # Fallback: givenName + sn
      filter = Net::LDAP::Filter.eq('givenName', parts[0]) &
               Net::LDAP::Filter.eq('sn',        parts[1])
      results = ldap.search(base: auth_source.base_dn, filter: filter, attributes: attrs)
      results&.first
    end
  end
end
