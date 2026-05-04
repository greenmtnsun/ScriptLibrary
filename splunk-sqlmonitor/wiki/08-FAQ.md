# 08 — FAQ

### Why no perfmon / DB Connect / Splunk SQL add-on?

Because the tenant we built for is event-driven only. Add those later if/when available — none of this stack breaks; new dashboards / panels just get added.

### Can the same dashboards work without the custom telemetry script?

Yes. Panels referencing EventCode 1001 / 2001 (custom telemetry) simply render empty. Everything else works from the standard Windows Event Log.

### Why SimpleXML AND Dashboard Studio?

- SimpleXML is portable, terse, and what most existing Splunk muscle memory expects.
- Dashboard Studio is the modern format, has better visualisations and a drag-resize editor.

Pick whichever your org standardises on. Or ship both and let users open whichever they prefer.

### Why a CSV inventory instead of dynamically discovering hosts?

Three reasons:
1. **Allow-list semantics.** Only inventoried hosts are in scope — prevents random workstations with `MSSQL` services from polluting dashboards.
2. **Enrichment.** `env`, `role`, `owner`, `tier` are not on the events themselves. The CSV is where business context joins technical telemetry.
3. **Operational discipline.** Decommissioning a server forces an inventory update. Without it you'd silently keep alerting on dead hosts.

### How do I add a new environment (e.g. `qa` or `dr`)?

1. Add the value to the `env` column in `sql_inventory.csv`.
2. Add a `<choice value="qa">QA</choice>` line to each dashboard's environment multiselect input.
3. (Optional) update the alert routing in `savedsearches.conf` if QA needs different SLA.

### Can I use this against Azure SQL / SQL MI / RDS?

Not directly — those don't write to Windows Event Log. You'd need:
- Azure Diagnostic Settings → Log Analytics / Event Hub → Splunk
- AWS CloudWatch Logs → Splunk
And then build new eventtypes that match their diagnostic categories. The dashboard structure (inventory CSV → eventtypes → panels) carries over unchanged.

### Why do alert names start with `SQL - P1 -`?

Sorting. In the Splunk **Settings → Searches, reports, alerts** UI, alphabetical sort puts all SQL alerts together, grouped by tier. Quick visual triage of "what could possibly be paging me right now".

### Why do all alerts ship `disabled = 1`?

Safety. Importing the conf file should never page anyone. You explicitly enable per alert as you wire up the routing.

### What's the cost (search head / SVC) of running all alerts?

| Alert | Cron | Lookback | Rough impact |
|---|---|---|---|
| Service Crash | every 5m | 5m | tiny — small filtered scan |
| Corruption | every 5m | 5m | tiny |
| Log/Data File Full | every 5m | 5m | tiny |
| AG Suspended | every 5m | 5m | tiny |
| Backup Failure | every 15m | 15m | tiny |
| Runaway Job | every 5m | 5m | tiny |
| Job Step Failure | every 15m | 15m | tiny |
| Failed Login Burst | every 15m | 15m | small |
| Silent Server | every 15m | 30m + subsearch | moderate (subsearch over fleet) |
| Daily Digest | 0 7 * * * | 24h | large but daily |
| Weekly Health | 0 6 * * 1 | 7d | large but weekly |
| Daily Backup Coverage | 0 6 * * * | 24h | medium |
| Monthly Trend | 0 6 1 * * | 30d | large but monthly |

For a fleet of <200 hosts on a healthy SH, this is negligible. For larger fleets, summary-index the Silent Server result and have the alert read from the summary.

### Can I summary-index everything for cheaper dashboards?

Yes — recommended once the fleet > a few hundred hosts. Pattern:

1. Create a scheduled search every 5m: 
   ```
   eventtype=sql_engine_events OR ... | eval host=lower(...) | lookup ... | where isnotnull(env)
   | bucket _time span=5m
   | stats count by _time host env EventCode SourceName
   | collect index=summary sourcetype=sql_fleet_summary
   ```
2. Re-point dashboard base searches at `index=summary sourcetype=sql_fleet_summary` instead of raw eventtypes.
3. Acceptance criteria: panels render in <1s even on 30-day lookback.

### Why are the dashboards dark theme?

Personal preference. Toggle `theme="dark"` to `theme="light"` in the SimpleXML files (or use the Studio theme switcher) for the opposite.

### Where do the SLAs come from for tier 1/2/3?

They're conventions in this stack, not enforced. Suggested:
- Tier 1 (prod, customer-facing): 99.95% — page on P1 24/7
- Tier 2 (stage, important internal): 99.5% — page during business hours, ticket overnight
- Tier 3 (dev, throwaway): best-effort — ticket only

Edit `savedsearches.conf` to make these real.
