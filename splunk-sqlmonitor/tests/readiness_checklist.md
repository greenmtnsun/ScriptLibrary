# Readiness Checklist

Run this after `tests/validate.sh` passes locally. It covers everything that needs a live Splunk to verify.

## Pre-flight (local)

- [ ] `bash tests/validate.sh` exits 0
- [ ] CSV reflects real Dev/Test/Stage/Prod hosts (not the mocks)
- [ ] Email recipients in `savedsearches.conf` updated to real DLs
- [ ] PagerDuty / Slack / webhook URLs filled in for any P1 alerts you intend to enable

## In Splunk — data presence

- [ ] `index=<your_index> sourcetype="WinEventLog:Application" | head 5` returns events
- [ ] `index=<your_index> sourcetype="WinEventLog:System" | head 5` returns events
- [ ] At least one inventoried host has produced an event in the last 24h:
  ```
  | inputlookup sql_inventory_lookup | fields host
  | join host [ search sourcetype="WinEventLog:*" earliest=-24h | eval host=lower(coalesce(ComputerName,host)) | stats count by host ]
  | stats count
  ```

## In Splunk — lookup

- [ ] `| inputlookup sql_inventory_lookup` returns the expected row count
- [ ] `| inputlookup sql_inventory_lookup | search env=prod | stats count` matches your prod count

## In Splunk — eventtypes

- [ ] Each eventtype matches at least one event in 24h:
  ```
  eventtype=sql_engine_events earliest=-24h | stats count
  eventtype=sql_agent_events  earliest=-24h | stats count
  eventtype=sql_service_events earliest=-24h | stats count
  ```
  (`sql_custom_telemetry` will be 0 if you haven't deployed `Invoke-TelemetryANDAnomoly.ps1` — that's fine.)

## Dashboards — Executive

- [ ] `Servers In Scope` matches the inventory count for the selected envs
- [ ] `Servers Reporting` ≥ 1 (ideally ≈ Servers In Scope minus genuinely-down hosts)
- [ ] `Silent Servers` is plausible (any non-zero must be explainable: known-down, decommissioned, UF issue)
- [ ] `Health Matrix` shows at least one row per env you selected
- [ ] Severity Trend chart has bars (or empty if your fleet is genuinely quiet)

## Dashboards — Operations

- [ ] Host dropdown auto-populates from inventory and respects the env filter
- [ ] Picking a known-busy host renders all panels
- [ ] Failed Login table parses `login_user` and `client_ip` (not blank)
- [ ] Job Failures table parses `job_name` (not blank)

## Dashboards — Security

- [ ] KPIs render
- [ ] Failure Reasons pie shows reasons (not 100% "(unparsed)")
- [ ] Heatmap shows host × hour cells

## Synthetic test data (optional but recommended)

If you have a non-prod test index to play in:

- [ ] Pick one block from `tests/sample_events.spl`, append `| collect index=<test_index> sourcetype="WinEventLog:Application"`, and run.
- [ ] Re-open the matching dashboard with that index in scope — confirm the new event appears.
- [ ] If using a test index, temporarily widen your eventtypes to include it (`index=<test_index> OR index=<prod_index>`) — revert after testing.

## Alerts — dry runs

For each alert you plan to enable:

- [ ] Run the alert's search manually with a wide lookback (`-7d`) — expected result count?
- [ ] If unexpectedly large: tune (see `wiki/06-Tuning-Guide.md`) before enabling
- [ ] Set `disabled = 0`, set `action.email.to`
- [ ] **Settings → Searches → click the alert → Run** to fire it once on demand
- [ ] Confirm receipt in email / pager / webhook destination
- [ ] Verify throttling: trigger a second time inside the suppress window — only one alert should fire

## Reports — first send

For each scheduled report you enable:

- [ ] Run on demand from the UI — does the email render correctly in Outlook / Gmail?
- [ ] Tables formatted (no raw `_raw` blob, no broken HTML)
- [ ] Subject line includes the run time

## Sign-off

- [ ] Rolled back the synthetic test events from any production index
- [ ] All P1 alerts pointed at on-call rotation, not individual mailboxes
- [ ] Wiki link added to your team's runbook landing page
- [ ] Wrote a short note in #dba (or equivalent) announcing the dashboards exist
