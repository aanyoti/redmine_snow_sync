class AddSnowMonthlyTargets < ActiveRecord::Migration[7.2]
  def up
    create_table :snow_monthly_targets do |t|
      t.integer  :year,           null: false
      t.integer  :month,          null: false
      t.integer  :target_count,   null: false, default: 0
      t.decimal  :target_mrr_zmw, precision: 15, scale: 4, default: 0
      t.decimal  :target_nrr_zmw, precision: 15, scale: 4, default: 0
      t.decimal  :target_mrr_usd, precision: 15, scale: 4, default: 0
      t.decimal  :target_nrr_usd, precision: 15, scale: 4, default: 0
      t.datetime :locked_at
      t.integer  :locked_by_id
      t.text     :issue_ids
      t.timestamps null: false
    end
    add_index :snow_monthly_targets, [:year, :month], unique: true

    unless IssueCustomField.exists?(name: 'Active WIP')
      cf = IssueCustomField.create!(
        name:          'Active WIP',
        field_format:  'bool',
        is_required:   false,
        is_for_all:    true,
        searchable:    true,
        default_value: '0'
      )
      Tracker.where(id: [14, 18]).each { |t| cf.trackers << t }
    end
  end

  def down
    drop_table :snow_monthly_targets
    IssueCustomField.find_by(name: 'Active WIP')&.destroy
  end
end
