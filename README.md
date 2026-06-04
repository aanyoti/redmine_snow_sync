# redmine_snow_sync

A Redmine plugin built for **Liquid IT Zambia** that integrates ServiceNow, Salesforce and Microsoft Teams into a unified commercial order management workflow.

## Features

- **ServiceNow → Redmine sync** — polls `sc_request` table every 15 minutes, creates issues with attachments
- **PDF enrichment** — extracts NRR/MRR, Account Number and Prepared By from CECLT quote PDFs
- **KAM auto-assignment** — looks up Prepared By name in Active Directory, creates Redmine user, adds to KAMs group as issue watcher
- **Tracker classification** — auto-assigns new orders to Commercial Orders (tracker 14) or C2 (tracker 18) based on keywords in subject/description
- **Order consolidation** — multiple SNow requests for the same order number are merged into one Redmine issue; components listed in the Services custom field
- **Salesforce segment enrichment** — Power Automate flow POSTs Salesforce data to enrich Redmine issues with customer segment and opportunity type
- **Salesforce orders sync** — full Salesforce dataset upserted into PostgreSQL for reporting
- **SLA timers** — tracks time-in-status per issue, sends email + journal note on breach
- **Reporting API** — REST endpoints for Power BI consumption

---

## Requirements

- Redmine 6.0+ on Rails 7.2+
- PostgreSQL
- Ruby 3.3+
- `pdftotext` (poppler-utils) installed on the server
- Active Directory accessible for LDAP user lookups
- `mysql2` gem (for MySQL BI server connectivity)

---

## Installation

```bash
cd /var/lib/redmine/plugins
git clone git@github.com:aanyoti/redmine_snow_sync.git
cd /var/lib/redmine
bundle install
RAILS_ENV=production bundle exec rake redmine:plugins:migrate NAME=redmine_snow_sync
touch tmp/restart.txt
```

---

## Configuration

Go to **Admin → ServiceNow Sync** and fill in:

| Setting | Description |
|---------|-------------|
| ServiceNow URL | `https://oneliquidsupport.service-now.com` |
| Username / Password | SNow API credentials (WebServiceUser) |
| Target Project | Organic (id=5) |
| Target Tracker | Commercial Orders (id=14) |
| Assignment Groups | `Zambia Service Delivery,Zambia Technical Services,Zambia Site Survey` |
| Poll States | `1,2` (Open, Work in Progress) |
| Delivery Stage | `Awaiting Approval` |
| Field — Order | SNow field name for the order number |
| Field — Account | SNow field name for the account |
| Field — Service | SNow field name for the service/SVC ID |
| Days Back | `0` to use rolling `last_sync_at`; `>0` for fixed lookback |
| ZMW/USD Rate | Exchange rate for currency conversion (default 27.50) |
| Webhook Token | Secret token for all API endpoints |

---

## Cron Jobs

Add to crontab (`crontab -e`):

```bash
# SNow sync every 15 minutes
*/15 * * * * cd /var/lib/redmine && RAILS_ENV=production /usr/local/bin/bundle exec rake redmine:snow_sync:run >> /var/log/redmine_snow_sync.log 2>&1

# SLA breach check every 30 minutes
*/30 * * * * cd /var/lib/redmine && RAILS_ENV=production /usr/local/bin/bundle exec rake redmine:snow_sync:sla_check >> /var/log/redmine_sla.log 2>&1
```

---

## API Endpoints

All endpoints require the header `X-Webhook-Token: <token>`.

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/snow_sync/segments` | Enriches issues with segment + opportunity type from Salesforce |
| `POST` | `/api/snow_sync/salesforce_sync` | Upserts full Salesforce dataset into PostgreSQL |
| `POST` | `/api/snow_sync/retail_preview` | Captures raw payload to `log/retail_preview.json` for schema inspection |
| `GET` | `/api/snow_sync/report` | Redmine flat view — one row per issue (Power BI) |
| `GET` | `/api/snow_sync/salesforce_report` | Combined Redmine + Salesforce view (Power BI) |

Optional query param: `?updated_since=YYYY-MM-DD` on GET endpoints.

---

## Power Automate Flows

### Salesforce Enrichment Flow
1. **Power BI — Run a query** against `LITZM-Service Delivery Report-FY27`
2. **Select** — maps fields to `{order_number, account_name, segment, opportunity_type}`
3. **Filter array** — removes rows where segment is `-` or empty
4. **Compose** — `body('Filter_array')`
5. **HTTP POST** to `/api/snow_sync/segments` — body (template): `@{outputs('Compose')}`
6. **Select 2** — maps all Power BI fields to `salesforce_orders` schema
7. **Compose 2** — `body('Select_2')`
8. **HTTP POST** to `/api/snow_sync/salesforce_sync` — body: `@{outputs('Compose_2')}`

> Recurrence: hourly, 07:00–23:00 daily

---

## Tracker Classification

New SNow imports are automatically assigned to the correct tracker based on keywords in the issue subject and description. Configured in `lib/snow_sync/tracker_classifier.rb`.

| Tracker | Service Type | Keywords |
|---------|-------------|---------|
| C2 (18) | VoIP | SIP Trunk, SIP Channel, Number Block, VoIP, IVR, Conference Facilities |
| C2 (18) | M365 | Microsoft 365, M365, Office 365, Teams, SharePoint, Intune, Dynamics, Exchange |
| C2 (18) | Cloud - Azure | Azure |
| C2 (18) | Cloud - AWS | AWS, Amazon Web Services |
| C2 (18) | Cloud - Google | Google Workspace, Google Cloud, GCP |
| C2 (18) | Cybersecurity | Cybersecurity, Firewall, SOC, SIEM, EDR, FortiGate, Sophos |
| C2 (18) | Cloud PBX | Cloud PBX, Hosted PBX, UCaaS |
| C2 (18) | Licensing | Licensing, License, Licence |
| Commercial Orders (14) | — | Everything else (DIA, E-LINE, IPT, MPLS, Fiber) |

---

## SLA Timers

Target durations configured in `app/models/snow_sla_timer.rb` → `SLA_DAYS` constant.

| Status | Target |
|--------|--------|
| Service Request Review | 2 calendar days |
| Service Scheduling | 1 calendar day |

Additional statuses will be added as the workflow is finalised. On breach: journal note added to the issue + email sent to assignee and watchers.

---

## PostgreSQL Views

| View | Description |
|------|-------------|
| `commercial_orders_flat` | One row per Redmine issue (tracker 14, project 5), all CFs pivoted |
| `commercial_orders_complete` | Joins `commercial_orders_flat` with `salesforce_orders` on order number |

---

## Database Migrations

| # | Migration | Description |
|---|-----------|-------------|
| 001 | `create_snow_sync_records` | Deduplication table (unique index on `snow_sys_id`) |
| 002 | `setup_snow_custom_fields` | Core SNow custom fields |
| 003 | `add_pdf_custom_fields` | Account Number, Prepared By, NRR/MRR (ZMW) |
| 004 | `add_usd_custom_fields` | NRR/MRR (USD) |
| 005 | `add_opportunity_type_field` | Opportunity Type CF |
| 006 | `create_commercial_orders_view` | `commercial_orders_flat` PostgreSQL view |
| 007 | `create_salesforce_orders_table` | `salesforce_orders` table + initial combined view |
| 008 | `update_complete_view_filter_billable` | Filters Salesforce join to billable rows |
| 009 | `create_c2_tracker` | C2 tracker, 9 statuses, Service Type + Services CFs |
| 010 | `associate_commercial_cfs_with_c2` | Shares Commercial CFs with C2 tracker |
| 011 | `commercial_workflow_statuses` | On Hold statuses, Rejection Pending, Build Approval |
| 012 | `create_sla_timers` | `snow_sla_timers` table for SLA tracking |

---

## Dependencies (third-party plugins required)

These plugins must be installed separately:

| Plugin | Version | Source |
|--------|---------|--------|
| Advanced Workflows | 1.0.8 | redmine-kanban.com/plugins/advanced_workflow |
| Assign Workflow | 1.0.0 | Ahau Software |
| Advanced Checklists | 2.4.3 | redmine-kanban.com/plugins/checklists |
| Kanban Board | 2.6.0 | redmine-kanban.com/plugins/kanban |

---

## Environment

- **Redmine server**: projects-litzm.liquidtelecom.zm
- **Stack**: Apache + Passenger, PostgreSQL
- **BI MySQL server**: 10.169.62.54:3306 / database: `liquid_bi`
- **ServiceNow**: oneliquidsupport.service-now.com
