module SnowSync
  class IssueHook < Redmine::Hook::ViewListener
    render_on :view_issues_show_details_bottom, partial: 'snow_sync/sla_status'
  end
end
