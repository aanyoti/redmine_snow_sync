module SnowSync
  module ActiveWipHelper
    def self.authorized?(user = User.current)
      return false if user.nil? || !user.logged?
      return true  if user.admin?
      tech_lead?(user)
    end

    def self.tech_lead?(user)
      user.memberships.flat_map(&:roles).any? { |r| r.name == 'Tech Lead' }
    end
  end
end
