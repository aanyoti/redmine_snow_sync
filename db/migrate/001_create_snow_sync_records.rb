class CreateSnowSyncRecords < ActiveRecord::Migration[7.0]
  def change
    create_table :snow_sync_records do |t|
      t.string   :snow_sys_id,  null: false, index: { unique: true }
      t.string   :snow_number
      t.integer  :issue_id
      t.string   :sync_status,  default: 'ok'
      t.text     :sync_error
      t.datetime :synced_at
      t.timestamps
    end
  end
end
