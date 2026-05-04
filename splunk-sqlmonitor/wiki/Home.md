# SQL Server Fleet Monitoring — Wiki

This wiki documents an event-driven Splunk monitoring stack for a fleet of SQL Servers across Dev/Test/Stage/Prod. It uses **only** Windows Event Log data forwarded by the Universal Forwarder — no add-ons, no perfmon, no DB Connect, no SQL ERRORLOG file ingestion.

## Pages

| # | Page | What's in it |
|---|---|---|
| 01 | [Overview & Architecture](01-Overview.md) | High-level design, data flow, what is/isn't possible without add-ons |
| 02 | [Event Reference](02-Event-Reference.md) | Every SQL EventID we monitor, what it means, severity, action |
| 03 | [Inventory Maintenance](03-Inventory-Maintenance.md) | How to add/remove servers; CSV format; matching `host` correctly |
| 04 | [Dashboard Tour](04-Dashboard-Tour.md) | Panel-by-panel walkthrough of Executive, Operations, Security |
| 05 | [Alert Runbook](05-Alert-Runbook.md) | Per-alert response procedure (P1/P2/P3) |
| 06 | [Tuning Guide](06-Tuning-Guide.md) | Threshold and suppression knobs; how to silence false positives |
| 07 | [Troubleshooting](07-Troubleshooting.md) | "Why is X empty?", host-name mismatches, index access, lookup gotchas |
| 08 | [FAQ](08-FAQ.md) | Common questions and design rationale |
| 09 | [Top 10 Risks](09-Top10-Risks.md) | Strategic failure modes and how to prevent them |

## Quick start

1. Read [01-Overview](01-Overview.md) (5 min)
2. Follow [`DEPLOY.md`](../DEPLOY.md) to import the lookup, eventtypes, dashboards, and alerts
3. Replace [the mock inventory CSV](../sql_inventory.csv) with your real Dev/Test/Stage/Prod lists ([03-Inventory-Maintenance](03-Inventory-Maintenance.md))
4. Run the [readiness checklist](../tests/readiness_checklist.md)
5. Wire up a couple of P1 alerts to your pager ([05-Alert-Runbook](05-Alert-Runbook.md))
