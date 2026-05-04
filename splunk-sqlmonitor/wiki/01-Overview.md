# 01 — Overview & Architecture

## Goal

Give DBAs and on-call engineers cross-environment visibility into SQL Server fleet health using only data that is **already** flowing into Splunk via the Universal Forwarder's Windows Event Log inputs.

## Constraints (intentional)

- No Splunk add-ons (no Splunk_TA_microsoft-sqlserver, no DB Connect)
- No perfmon counters
- No SQL Server ERRORLOG file ingestion
- No Extended Events / system_health
- Splunk is "mainly event driven"

These constraints define what we can and can't show — see [02-Event-Reference](02-Event-Reference.md) and [08-FAQ](08-FAQ.md).

## Data flow

```
SQL Server hosts (Dev/Test/Stage/Prod)
        │
        │ Windows Event Log (Application + System)
        │  - SourceName: MSSQLSERVER / MSSQL$<inst>
        │  - SourceName: SQLSERVERAGENT / SQLAgent$<inst>
        │  - SourceName: Service Control Manager (SQL services only)
        │  - SourceName: SQLAgentTelemetry (custom — optional)
        ▼
Splunk Universal Forwarder
        │  inputs.conf:
        │    [WinEventLog://Application]  → index=wineventlog (typical)
        │    [WinEventLog://System]       → index=wineventlog
        ▼
Splunk Indexers
        │
        ▼
Splunk Search Head (this app)
        │
        ├─ Lookup:    sql_inventory_lookup  (CSV — host → env/role/AG/owner/tier)
        ├─ Eventtypes: sql_engine_events, sql_agent_events,
        │             sql_service_events, sql_custom_telemetry
        ├─ Dashboards: Executive, Operations, Security
        │             (SimpleXML and Dashboard Studio versions both shipped)
        └─ Alerts:    9 scheduled (P1/P2/P3)
                     4 scheduled reports (daily / weekly / monthly)
```

## Component map

| Layer | Artifact | File |
|---|---|---|
| Inventory | Server CSV | `sql_inventory.csv` |
| Inventory | Lookup definition | `transforms.conf` |
| Search abstraction | Eventtypes | `eventtypes.conf` |
| UI — Classic | Executive dashboard | `sql_executive_dashboard.xml` |
| UI — Classic | Operations dashboard | `sql_operations_dashboard.xml` |
| UI — Classic | Security dashboard | `sql_security_dashboard.xml` |
| UI — Studio | Executive dashboard | `sql_executive_dashboard_studio.json` |
| UI — Studio | Operations dashboard | `sql_operations_dashboard_studio.json` |
| UI — Studio | Security dashboard | `sql_security_dashboard_studio.json` |
| Alerts + Reports | Saved searches | `savedsearches.conf` |
| Deployment | Step-by-step install | `DEPLOY.md` |
| Tests | Readiness checklist + sample data | `tests/` |
| Docs | This wiki | `wiki/` |

## Design decisions

1. **CSV inventory drives everything.** Every dashboard panel and every alert filters with `lookup sql_inventory_lookup host`. Hosts not in the CSV are intentionally excluded — keeps the noise floor low and forces inventory hygiene.
2. **Eventtypes hide the messy source names.** `MSSQL$INST1` / `MSSQL$INST2` / `MSSQLSERVER` collapse into one `sql_engine_events`. Add a new instance pattern → edit `eventtypes.conf` once, every panel/alert updates.
3. **Two dashboard formats, one source of truth.** SimpleXML and Studio JSON ship the same searches in two presentation layers. Pick whichever you prefer — they coexist.
4. **Severity tiers, not "alert on everything".** P1 pages, P2 tickets, P3 reports. Throttling is built in (`alert.suppress.fields`) so a flapping host won't burst the on-call.
5. **All alerts ship `disabled = 1`.** Importing the file does not page anyone. You opt in alert-by-alert.
