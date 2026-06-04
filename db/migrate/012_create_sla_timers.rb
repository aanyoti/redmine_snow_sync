class CreateSlaTimers < ActiveRecord::Migration[7.0]
  def up
    create_table :snow_sla_timers do |t|
      t.integer  :issue_id,       null: false
      t.integer  :status_id,      null: false
      t.datetime :entered_at,     null: false
      t.datetime :due_at                        # null = no SLA for this status
      t.datetime :notified_at                   # last breach notification sent
      t.datetime :exited_at                     # set when issue leaves this status
      t.boolean  :breached,       default: false
    end

    add_index :snow_sla_timers, [:issue_id, :status_id]
    add_index :snow_sla_timers, :due_at
    add_index :snow_sla_timers, :exited_at
  end

  def down
    drop_table :snow_sla_timers
  end
end
