module SnowSync
  module VersionsControllerPatch
    CONTRACTOR_ROLE_ID = 20

    def index
      render_403 if contractor_only_user?
      super unless performed?
    end

    private

    def contractor_only_user?
      return false unless User.current.is_a?(User) && User.current.logged?
      ids = User.current.memberships.flat_map(&:role_ids).uniq
      ids.include?(CONTRACTOR_ROLE_ID) && (ids - [CONTRACTOR_ROLE_ID]).empty?
    end
  end
end
