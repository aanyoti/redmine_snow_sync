module SnowSync
  module ActiveWipHelper
    DEFAULT_GROUPS = ['Service Delivery', 'Projects'].freeze

    def self.authorized?(user = User.current)
      return false if user.nil? || !user.logged?
      return true  if user.admin?
      return true  if commercial_lead?(user)
      allowed = Setting.plugin_redmine_snow_sync['active_wip_groups']
                       .presence&.split(',')&.map(&:strip) || DEFAULT_GROUPS
      user.groups.where(name: allowed).exists?
    end

    def self.commercial_lead?(user)
      user.memberships.flat_map(&:roles).any? { |r| r.name == 'Commercial Lead' }
    end
  end
end
