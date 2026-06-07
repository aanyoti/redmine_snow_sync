class SlaReportView < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL
      CREATE OR REPLACE VIEW snow_sla_report_view AS
      SELECT
        st.id                                                          AS timer_id,
        st.issue_id,
        i.subject,
        t.name                                                         AS tracker,
        s.name                                                         AS status_name,
        cv_acct.value                                                  AS account,
        cv_order.value                                                 AS order_number,
        st.entered_at,
        st.due_at,
        st.exited_at,
        st.breached,
        st.notified_at,
        ROUND(
          EXTRACT(EPOCH FROM (COALESCE(st.exited_at, NOW()) - st.entered_at)) / 86400.0,
          2
        )                                                              AS elapsed_days,
        CASE WHEN st.due_at IS NOT NULL
          THEN ROUND(EXTRACT(EPOCH FROM (st.due_at - st.entered_at)) / 86400.0, 2)
          ELSE NULL
        END                                                            AS target_days,
        CASE
          WHEN st.exited_at IS NOT NULL AND st.due_at IS NOT NULL AND st.exited_at <= st.due_at
            THEN 'Met'
          WHEN st.exited_at IS NOT NULL AND st.due_at IS NOT NULL AND st.exited_at > st.due_at
            THEN 'Breached'
          WHEN st.exited_at IS NOT NULL AND st.due_at IS NULL
            THEN 'Closed (no target)'
          WHEN st.exited_at IS NULL AND st.due_at IS NOT NULL AND NOW() > st.due_at
            THEN 'Breached (open)'
          WHEN st.exited_at IS NULL AND st.due_at IS NULL
            THEN 'Open (no target)'
          ELSE 'On Track'
        END                                                            AS sla_result
      FROM snow_sla_timers st
      JOIN issues        i  ON i.id  = st.issue_id
      JOIN trackers      t  ON t.id  = i.tracker_id
      JOIN issue_statuses s ON s.id  = st.status_id
      LEFT JOIN custom_values cv_acct  ON cv_acct.customized_id  = st.issue_id
                                      AND cv_acct.custom_field_id  = 72
      LEFT JOIN custom_values cv_order ON cv_order.customized_id = st.issue_id
                                      AND cv_order.custom_field_id = 55;
    SQL
  end

  def down
    execute "DROP VIEW IF EXISTS snow_sla_report_view;"
  end
end
