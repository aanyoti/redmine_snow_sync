class SnowSyncRecord < ActiveRecord::Base
  belongs_to :issue, optional: true
  validates  :snow_sys_id, presence: true, uniqueness: true

  scope :recent, -> { order(synced_at: :desc).limit(25) }

  def self.synced?(sys_id)
    exists?(snow_sys_id: sys_id)
  end
end
