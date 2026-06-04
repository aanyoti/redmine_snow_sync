class CreateCommercialOrdersView < ActiveRecord::Migration[7.0]
  def up
    execute <<~SQL
      CREATE OR REPLACE VIEW commercial_orders_flat AS
      SELECT
        i.id,
        i.subject,
        s.name                                                        AS status,
        e.name                                                        AS priority,
        CASE WHEN u.id IS NOT NULL
          THEN u.firstname || ' ' || u.lastname END                   AS assignee,
        ic.name                                                       AS segment,
        v.name                                                        AS target_version,
        i.start_date,
        i.due_date,
        i.done_ratio,
        i.closed_on,
        i.created_on,
        i.updated_on,
        MAX(CASE WHEN cv.custom_field_id = 55  THEN cv.value END)    AS order_number,
        MAX(CASE WHEN cv.custom_field_id = 71  THEN cv.value END)    AS snow_request_number,
        MAX(CASE WHEN cv.custom_field_id = 72  THEN cv.value END)    AS account,
        MAX(CASE WHEN cv.custom_field_id = 73  THEN cv.value END)    AS requested_for,
        MAX(CASE WHEN cv.custom_field_id = 74  THEN cv.value END)    AS service,
        MAX(CASE WHEN cv.custom_field_id = 75  THEN cv.value END)    AS snow_opened,
        MAX(CASE WHEN cv.custom_field_id = 76  THEN cv.value END)    AS assignment_group,
        MAX(CASE WHEN cv.custom_field_id = 78  THEN cv.value END)    AS service_delivery_stage,
        MAX(CASE WHEN cv.custom_field_id = 80  THEN cv.value END)    AS account_number,
        MAX(CASE WHEN cv.custom_field_id = 81  THEN cv.value END)    AS prepared_by,
        MAX(CASE WHEN cv.custom_field_id = 82  THEN cv.value END)    AS nrr_zmw,
        MAX(CASE WHEN cv.custom_field_id = 83  THEN cv.value END)    AS mrr_zmw,
        MAX(CASE WHEN cv.custom_field_id = 84  THEN cv.value END)    AS nrr_usd,
        MAX(CASE WHEN cv.custom_field_id = 85  THEN cv.value END)    AS mrr_usd,
        MAX(CASE WHEN cv.custom_field_id = 88  THEN cv.value END)    AS opportunity_type,
        MAX(CASE WHEN cv.custom_field_id = 50  THEN cv.value END)    AS predecessor_issue,
        MAX(CASE WHEN cv.custom_field_id = 53  THEN cv.value END)    AS rejection_reason,
        MAX(CASE WHEN cv.custom_field_id = 58  THEN cv.value END)    AS contractor_name
      FROM issues i
      JOIN issue_statuses  s  ON s.id  = i.status_id
      JOIN enumerations    e  ON e.id  = i.priority_id
      LEFT JOIN users           u  ON u.id  = i.assigned_to_id
      LEFT JOIN issue_categories ic ON ic.id = i.category_id
      LEFT JOIN versions         v  ON v.id  = i.fixed_version_id
      LEFT JOIN custom_values    cv ON cv.customized_type = 'Issue'
                                   AND cv.customized_id   = i.id
      WHERE i.tracker_id = 14
        AND i.project_id = 5
      GROUP BY
        i.id, i.subject, s.name, e.name,
        u.id, u.firstname, u.lastname,
        ic.name, v.name,
        i.start_date, i.due_date, i.done_ratio, i.closed_on,
        i.created_on, i.updated_on;
    SQL
  end

  def down
    execute "DROP VIEW IF EXISTS commercial_orders_flat;"
  end
end
