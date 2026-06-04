class CreateSalesforceOrdersTable < ActiveRecord::Migration[7.0]
  def up
    create_table :salesforce_orders do |t|
      t.string  :subscription_id,            null: false         # Salesforce unique ID — upsert key
      t.string  :order_number                                     # ON00XXXXXX — join key to Redmine
      t.string  :customer_order_number                            # CECLT format (CloudSense ref)
      t.string  :lt_account_number
      t.string  :account_name
      t.string  :lt_opp_number
      t.string  :opportunity_type
      t.string  :customer_segment
      t.string  :subscription_number
      t.string  :subscription_name
      t.string  :primary_service_number
      t.text    :service_address
      t.string  :service_address_lookup
      t.string  :access_type
      t.string  :currency
      t.string  :contract_term
      t.string  :sf_status
      t.string  :change_type
      t.string  :upgraded_opportunity
      t.string  :differential_nrr_amount
      t.string  :differential_nrr_currency
      t.string  :differential_mrr_amount
      t.string  :differential_mrr_currency
      t.string  :operating_country
      t.string  :account_owner
      t.string  :service_delivery_engineer
      t.string  :service_delivery_manager
      t.string  :service_delivery_reason
      t.text    :delivery_milestones
      t.string  :milestone_target_date
      t.string  :adjusted_days_to_deliver
      t.string  :ltk_sdu_internal_process
      t.string  :case_number
      t.string  :case_owner
      t.text    :sf_subject
      t.string  :snow_request_number
      t.string  :sf_created_date
      t.datetime :synced_at,                null: false, default: -> { 'NOW()' }
    end

    add_index :salesforce_orders, :subscription_id, unique: true
    add_index :salesforce_orders, :order_number

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
      LEFT JOIN salesforce_orders sf ON sf.order_number = r.order_number;
    SQL
  end

  def down
    execute "DROP VIEW IF EXISTS commercial_orders_complete;"
    drop_table :salesforce_orders
  end
end
