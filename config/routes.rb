Rails.application.routes.draw do
  get  'snow_sync_settings',                 to: 'snow_sync_settings#index',          as: 'snow_sync_settings'
  post 'snow_sync_settings',                 to: 'snow_sync_settings#update'
  post 'snow_sync_settings/run_now',         to: 'snow_sync_settings#run_now',        as: 'snow_sync_run_now'
  post 'snow_sync_settings/test_connection',  to: 'snow_sync_settings#test_connection',  as: 'snow_sync_test_connection'
  post 'snow_sync_settings/recalculate_rates', to: 'snow_sync_settings#recalculate_rates', as: 'snow_sync_recalculate_rates'
  post 'api/snow_sync/segments',             to: 'snow_sync_webhook#segments',        as: 'snow_sync_segments_webhook'
  get  'api/snow_sync/report',              to: 'snow_sync_webhook#report',          as: 'snow_sync_report'
  post 'api/snow_sync/salesforce_sync',     to: 'snow_sync_webhook#salesforce_sync', as: 'snow_sync_salesforce_sync'
  get  'api/snow_sync/salesforce_report',   to: 'snow_sync_webhook#salesforce_report', as: 'snow_sync_salesforce_report'
  post 'api/snow_sync/retail_preview',      to: 'snow_sync_webhook#retail_preview',   as: 'snow_sync_retail_preview'
  get  'snow_sla_report',                   to: 'snow_sla_report#index',             as: 'snow_sla_report'
end
