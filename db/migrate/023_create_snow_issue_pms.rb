class CreateSnowIssuePms < ActiveRecord::Migration[7.2]
  def up
    create_table :snow_issue_pms do |t|
      t.integer :issue_id,   null: false
      t.integer :pm_user_id
      t.timestamps
    end
    add_index :snow_issue_pms, :issue_id, unique: true
  end

  def down
    drop_table :snow_issue_pms
  end
end
