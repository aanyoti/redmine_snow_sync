class UpdateCompleteViewFilterBillable < ActiveRecord::Migration[7.0]
  def up
    execute <<~SQL
      CREATE OR REPLACE VIEW commercial_orders_complete AS
      SELECT
        r.id                        AS redmine_id,
        r.subject,
        r.status,
        r.priority,
        r.assignee,
        r.segment,
        r.target_version,
        r.start_date,
        r.due_date,
        r.done_ratio,
        r.closed_on,
        r.created_on,
        r.updated_on,
        r.order_number,
        r.snow_request_number,
        r.account,
        r.requested_for,
        r.service,
        r.snow_opened,
        r.assignment_group,
        r.service_delivery_stage,
        r.account_number,
        r.prepared_by,
        r.nrr_zmw,
        r.mrr_zmw,
        r.nrr_usd,
        r.mrr_usd,
        r.opportunity_type,
        r.predecessor_issue,
        r.rejection_reason,
        r.contractor_name,
        sf.subscription_id,
        sf.customer_order_number,
        sf.lt_account_number,
        sf.lt_opp_number,
        sf.subscription_number,
        sf.subscription_name,
        sf.primary_service_number,
        sf.service_address,
        sf.service_address_lookup,
        sf.access_type,
        sf.currency,
        sf.contract_term,
        sf.sf_status,
        sf.change_type,
        sf.upgraded_opportunity,
        sf.differential_nrr_amount,
        sf.differential_nrr_currency,
        sf.differential_mrr_amount,
        sf.differential_mrr_currency,
        sf.operating_country,
        sf.account_owner,
        sf.service_delivery_engineer,
        sf.service_delivery_manager,
        sf.service_delivery_reason,
        sf.delivery_milestones,
        sf.milestone_target_date,
        sf.adjusted_days_to_deliver,
        sf.ltk_sdu_internal_process,
        sf.case_number,
        sf.case_owner,
        sf.sf_subject,
        sf.snow_request_number      AS sf_snow_request_number,
        sf.sf_created_date,
        sf.synced_at                AS sf_synced_at
      FROM commercial_orders_flat r
      LEFT JOIN salesforce_orders sf ON sf.order_number = r.order_number
        AND (
          CASE WHEN sf.differential_nrr_amount ~ '^[0-9]+(\.[0-9]+)?$'
               THEN sf.differential_nrr_amount::numeric ELSE 0 END > 0
          OR
          CASE WHEN sf.differential_mrr_amount ~ '^[0-9]+(\.[0-9]+)?$'
               THEN sf.differential_mrr_amount::numeric ELSE 0 END > 0
        );
    SQL
  end

  def down
    execute <<~SQL
      CREATE OR REPLACE VIEW commercial_orders_complete AS
      SELECT
        r.id AS redmine_id, r.subject, r.status, r.priority, r.assignee,
        r.segment, r.target_version, r.start_date, r.due_date, r.done_ratio,
        r.closed_on, r.created_on, r.updated_on, r.order_number,
        r.snow_request_number, r.account, r.requested_for, r.service,
        r.snow_opened, r.assignment_group, r.service_delivery_stage,
        r.account_number, r.prepared_by, r.nrr_zmw, r.mrr_zmw,
        r.nrr_usd, r.mrr_usd, r.opportunity_type, r.predecessor_issue,
        r.rejection_reason, r.contractor_name,
        sf.subscription_id, sf.customer_order_number, sf.lt_account_number,
        sf.lt_opp_number, sf.subscription_number, sf.subscription_name,
        sf.primary_service_number, sf.service_address, sf.service_address_lookup,
        sf.access_type, sf.currency, sf.contract_term, sf.sf_status,
        sf.change_type, sf.upgraded_opportunity, sf.differential_nrr_amount,
        sf.differential_nrr_currency, sf.differential_mrr_amount,
        sf.differential_mrr_currency, sf.operating_country, sf.account_owner,
        sf.service_delivery_engineer, sf.service_delivery_manager,
        sf.service_delivery_reason, sf.delivery_milestones,
        sf.milestone_target_date, sf.adjusted_days_to_deliver,
        sf.ltk_sdu_internal_process, sf.case_number, sf.case_owner,
        sf.sf_subject, sf.snow_request_number AS sf_snow_request_number,
        sf.sf_created_date, sf.synced_at AS sf_synced_at
      FROM commercial_orders_flat r
      LEFT JOIN salesforce_orders sf ON sf.order_number = r.order_number;
    SQL
  end
end
