class SnowIssuePm < ApplicationRecord
  self.table_name = 'snow_issue_pms'
  belongs_to :issue
  belongs_to :pm, class_name: 'User', foreign_key: :pm_user_id, optional: true
end
