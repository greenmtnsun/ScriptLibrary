# SQL Server Fleet Dashboards — Splunk Deployment

Files in this folder:

| File | Purpose |
|---|---|
| `sql_inventory.csv` | Mock server inventory (host, env, role, AG cluster, owner). Replace with real list when ready. |
| `transforms.conf` | Defines the `sql_inventory_lookup` lookup definition. |
| `eventtypes.conf` | Defines reusable eventtypes for SQL engine, SQL Agent, service control, and custom telemetry events. |
| `sql_executive_dashboard.xml` | KPI / exec view — **SimpleXML** (Classic dashboards). |
| `sql_operations_dashboard.xml` | DBA / on-call deep-dive view — **SimpleXML** (Classic dashboards). |
| `sql_security_dashboard.xml` | Authentication / brute-force / off-hours view — **SimpleXML**. |
| `sql_executive_dashboard_studio.json` | KPI / exec view — **Dashboard Studio** (modern JSON). |
| `sql_operations_dashboard_studio.json` | DBA / on-call deep-dive view — **Dashboard Studio**. |
| `sql_security_dashboard_studio.json` | Security view — **Dashboard Studio**. |
| `savedsearches.conf` | 9 scheduled alerts (P1/P2/P3) + 4 scheduled email reports (daily exec digest, weekly fleet health, daily backup coverage, monthly trend). |
| `wiki/` | Markdown wiki: overview, event reference, inventory upkeep, dashboard tour, alert runbook, tuning, troubleshooting, FAQ, top-10 risks. |
| `tests/validate.sh` | Local pre-deployment validator — runs 14 checks. Exit 0 = ready. |
| `tests/sample_events.spl` | Synthetic SQL event generator (uses `\| makeresults`) for smoke-testing dashboards without waiting for real events. |
| `tests/readiness_checklist.md` | In-Splunk verification checklist for after-import. |
| `tests/wrap_studio.py` | Helper used by the Makefile to wrap Studio JSON for on-disk install. |
| `Makefile` | One-shot build / package / install of a real Splunk `.spl` app. |
| `app-skeleton/` | Boilerplate files (`app.conf`, `default.meta`, nav) that Make assembles into the app. |
| `.github/workflows/validate.yml` | GitHub Actions CI: runs the validator + builds the `.spl` on every PR. |

You can import EITHER the SimpleXML pair OR the Studio JSON pair (or both — they coexist fine). Studio gives you the modern editor + drag-resize panels; SimpleXML is broadly compatible and more terse.

The dashboards depend ONLY on Windows Event Log data forwarded by the Universal Forwarder — no add-ons, no perfmon, no ERRORLOG file ingestion required.

---

## Prerequisites

1. Universal Forwarder installed on every SQL host with these inputs enabled (typical `inputs.conf`):
   ```
   [WinEventLog://Application]
   disabled = 0
   index = wineventlog

   [WinEventLog://System]
   disabled = 0
   index = wineventlog
   ```
2. The hosts emit events under standard SQL Server source names: `MSSQLSERVER` / `MSSQL$<instance>`, `SQLSERVERAGENT` / `SQLAgent$<instance>`. (Optional: `SQLAgentTelemetry` if you also deploy `Invoke-TelemetryANDAnomoly.ps1`.)
3. You have a Splunk app to host these objects. Easiest: use `search` (the default Search & Reporting app), or create a new app `sql_fleet`.

---

## Fast path — install as a packaged Splunk app (recommended)

If your Splunk admin is happy installing apps from a `.spl` file, skip Steps 1–4 entirely and use this:

```bash
# In the repo root (where this DEPLOY.md lives):
make help          # show targets
make validate      # run the 14-check pre-deploy validator
make package       # → produces dist/sql_fleet-1.0.0.spl
```

Then either:

**Splunk Web (easiest):**
1. **Apps → Manage Apps → Install app from file**
2. Upload `dist/sql_fleet-1.0.0.spl`
3. Restart when prompted

**CLI:**
```bash
$SPLUNK_HOME/bin/splunk install app dist/sql_fleet-1.0.0.spl -auth admin:...
$SPLUNK_HOME/bin/splunk restart
```

**Direct copy (no .spl):**
```bash
make install SPLUNK_HOME=/opt/splunk
$SPLUNK_HOME/bin/splunk restart
```

After install you'll have an app named **SQL Server Fleet Monitoring** with all 6 dashboards, lookup, eventtypes, and saved searches/alerts in place. Then jump to Step 5 (smoke test) and Step 6 (replace the mock inventory).

If you'd rather install the pieces by hand (e.g. into the existing Search & Reporting app), continue with the manual steps below.

---

## Step 1 — Create / pick the target Splunk app

If creating a new app:
- Splunk Web: **Apps → Manage Apps → Create app**. Name = `sql_fleet`, Folder = `sql_fleet`, Visible = yes.
- Or on the search head: `mkdir -p $SPLUNK_HOME/etc/apps/sql_fleet/{default,lookups,local,metadata}`.

For the rest of this doc, `<APP>` = the app folder you chose (`search` or `sql_fleet`).

---

## Step 2 — Install the inventory lookup

1. **Upload the CSV**
   - Splunk Web: **Settings → Lookups → Lookup table files → New Lookup Table File**
     - Destination app: `<APP>`
     - Upload `sql_inventory.csv`
     - Destination filename: `sql_inventory.csv`
     - Permissions: shared globally (or to the app), read = Everyone, write = admin/dba
   - CLI alternative: copy `sql_inventory.csv` to `$SPLUNK_HOME/etc/apps/<APP>/lookups/sql_inventory.csv`.

2. **Define the lookup**
   - Splunk Web: **Settings → Lookups → Lookup definitions → New Lookup Definition**
     - Destination app: `<APP>`
     - Name: `sql_inventory_lookup`
     - Type: `File-based`
     - Lookup file: `sql_inventory.csv`
     - Advanced: tick **Case-sensitive matching = false**
   - CLI alternative: copy `transforms.conf` to `$SPLUNK_HOME/etc/apps/<APP>/local/transforms.conf` (merge if it already exists).

3. **Verify** in the search bar:
   ```
   | inputlookup sql_inventory_lookup
   ```
   You should see all 18 mock rows.

---

## Step 3 — Install the eventtypes

The dashboards reference 4 eventtypes (`sql_engine_events`, `sql_agent_events`, `sql_service_events`, `sql_custom_telemetry`).

- Splunk Web: **Settings → Event types → New Event Type** for each one. Copy the `search = ...` line from `eventtypes.conf` as the search string. App = `<APP>`. Sharing = globally or app-level.
- CLI alternative: copy `eventtypes.conf` to `$SPLUNK_HOME/etc/apps/<APP>/local/eventtypes.conf` (merge if it already exists).

**Important:** the eventtypes assume your forwarders write Windows events into a default index. If you use a non-default index (e.g. `index=wineventlog`), prepend that to each `search =` line, e.g.:
```
search = index=wineventlog (sourcetype="WinEventLog:Application") AND (SourceName="MSSQLSERVER" OR SourceName="MSSQL$*")
```

**Verify** in the search bar:
```
eventtype=sql_engine_events | head 5
eventtype=sql_agent_events  | head 5
eventtype=sql_service_events | head 5
```

---

## Step 4 — Import the two dashboards

For each XML file (`sql_executive_dashboard.xml`, `sql_operations_dashboard.xml`):

**Option A — Splunk Web (easiest)**
1. Go to the `<APP>` (e.g. Search & Reporting).
2. **Dashboards → Create New Dashboard → Dashboard → Classic**.
3. Give it any temporary title and Save.
4. Open the new dashboard, click **Edit → Source**.
5. Replace the entire XML with the contents of the file.
6. Save. The `<label>` tag becomes the displayed title.

**Option B — File system**
1. Copy the XML to: `$SPLUNK_HOME/etc/apps/<APP>/local/data/ui/views/`
   - Rename to match the desired URL slug, e.g.:
     - `sql_executive.xml`
     - `sql_operations.xml`
2. Restart Splunk (or `| reload` via REST: `curl -k -u admin:... https://<sh>:8089/servicesNS/admin/<APP>/data/ui/views/_reload`).
3. The dashboards appear under **Dashboards** in `<APP>`.

---

### Step 4b — Import the Dashboard Studio (JSON) versions

Studio dashboards are stored as a single JSON definition. Import path:

**Option A — Splunk Web (recommended)**
1. Go to the `<APP>` you chose (e.g. Search & Reporting).
2. **Dashboards → Create New Dashboard → Dashboard → Dashboard Studio**.
3. In the new (empty) Studio editor, click the **Source ⟨/⟩** icon (top toolbar).
4. Replace the entire JSON with the contents of `sql_executive_dashboard_studio.json` (or the operations file).
5. Click **Back** then **Save**. The `title` field becomes the dashboard name.

**Option B — File system**
1. Copy each JSON file to: `$SPLUNK_HOME/etc/apps/<APP>/local/data/ui/views/`
   - Rename to a stable URL slug, e.g. `sql_executive_studio.xml` and `sql_operations_studio.xml`.
   - Yes — Studio dashboards still live in `data/ui/views/` and use the `.xml` filename, but the file content is wrapped JSON. The wrapper Splunk expects on disk is:
     ```
     <dashboard version="2" theme="dark">
       <definition><![CDATA[
       { ... contents of the .json file ... }
       ]]></definition>
       <meta type="hiddenChrome"></meta>
     </dashboard>
     ```
   - For convenience, do the wrapping in Splunk Web instead (Option A) — it's two clicks and avoids the boilerplate.
2. Reload views: `curl -k -u admin:... https://<sh>:8089/servicesNS/admin/<APP>/data/ui/views/_reload`
   (or restart Splunk).

**Verify** by opening the dashboard from the Dashboards listing — Studio dashboards have a different icon than Classic ones.

---

## Step 4c — Install the alerts (savedsearches.conf)

The alert pack defines 9 scheduled searches (P1 / P2 / P3 severities). All ship with `disabled = 1` and only the `index=summary` action enabled, so importing them does NOT page anyone until you wire up routing.

**Option A — Splunk Web**
For each stanza in `savedsearches.conf`:
1. Paste the `search = ...` value into the search bar, run it, then **Save As → Alert**.
2. Set the schedule (`cron_schedule`), trigger (number of events > 0), throttle (`alert.suppress.*`), severity, and actions to match the conf file.
3. Repeat for each. Tedious but UI-friendly.

**Option B — File system (recommended for 9 alerts)**
1. Copy `savedsearches.conf` to `$SPLUNK_HOME/etc/apps/<APP>/local/savedsearches.conf` (merge with any existing file).
2. Edit each stanza you want active:
   - Set `disabled = 0`
   - Replace the `action.email.to` recipients
   - If using PagerDuty / webhook / Slack: set `action.webhook = 1` and `action.webhook.param.url = ...` (or use `action.pagerduty.*` if the PagerDuty add-on is installed)
3. `splunk restart` (or hit the REST endpoint: `curl -k -u admin:... https://<sh>:8089/services/admin/savedsearch/_reload`).

**Severity guide:**

| Tier | What | Suggested route |
|---|---|---|
| P1 | Service crash, corruption, log/data file full, AG suspended (prod) | Page on-call (PagerDuty / Opsgenie) |
| P2 | Backup failure, runaway job (Z≥5), Agent job step failure | Ticketing / email DBA team |
| P3 | Failed login burst, silent inventoried server | Email / dashboard / chat channel |

**Throttling note:** every alert uses `alert.suppress.fields` (host, db, ag_cluster, etc.) so a storm against one host produces one alert per `alert.suppress.period`, not hundreds.

---

## Step 5 — Smoke test

In the executive dashboard:
1. Set time range to `Last 24 hours`.
2. **Servers In Scope** should equal the count of inventory rows that match the env filter (18 with all envs selected, on the mock data).
3. **Servers Reporting** > 0 means events are landing.
4. **Silent Servers** > 0 means inventory rows exist that have NOT produced any events in the window — usually one of:
   - host name mismatch (UF reports FQDN, inventory has shortname, or vice versa)
   - SQL service is genuinely silent (test by stopping/starting a non-prod service)
   - index restriction blocking the search

In the operations dashboard:
1. Pick env = `prod`, host = `*`.
2. The Service Control panel should populate from the System log; confirm at least one start/stop pair per host.

---

## Step 6 — Replace mock inventory with the real list

When you have the real Dev/Test/Stage/Prod lists:

1. Edit `sql_inventory.csv` (or replace it via **Settings → Lookups → Lookup table files → Edit**).
2. Match the `host` column to whatever value lands in the `ComputerName` (or `host`) field on real events. To check what value Splunk sees, run:
   ```
   eventtype=sql_engine_events | stats count by host, ComputerName
   ```
   Use whichever value is consistent. The dashboards normalize via `eval host=lower(coalesce(ComputerName,host))`, so put the lowercase short hostname in the CSV unless your forwarders forward FQDNs.
3. Save. No restart required — lookups are re-read on every search.

---

## Continuous integration

The bundled GitHub Actions workflow (`.github/workflows/validate.yml`) runs on every push or PR that touches a CSV / XML / JSON / conf / Makefile / tests file. It:

1. Runs `bash tests/validate.sh` (14 checks)
2. Runs `make package` to build the `.spl`
3. Verifies the `.spl` contains every required file
4. Uploads the `.spl` as a build artifact (downloadable from the Actions tab)

To use it: drop this directory into a git repo, push to GitHub. No additional config required. The workflow runs on `ubuntu-latest` with Python 3.

To run the same checks locally before pushing:
```bash
make validate    # validator only (fast)
make package     # validator + build the .spl
```

A failing validator blocks the build, so a green CI badge means the artifacts are at least structurally sound. Real-data correctness still needs `tests/readiness_checklist.md` against your live Splunk.

---

## Customization notes

- **Add a new event class:** add it to `eventtypes.conf`, then reference the new eventtype from the panels' base searches.
- **Change severity coloring:** every panel has thresholds in `<format type="color">` blocks — tune the numbers to your tolerance.
- **Tighten / loosen "silent servers" window:** the time picker drives it. To make it permanent (e.g. always last hour), hardcode the silent-servers panel's `<earliest>`/`<latest>`.
- **Drilldown:** add `<drilldown><link>...</link></drilldown>` blocks to jump from exec → ops with the host token pre-filled. Easy to add when you have the real Splunk URL/app slug.
- **Alerts:** any panel search can be saved as a scheduled alert (**Save As → Alert** from the search). Recommended starters:
  - `eventtype=sql_service_events EventCode IN (7031,7034)` (service crash) — real-time, page on-call
  - `EventCode=3041` (backup failure) — every 15m, ticket
  - `EventCode IN (824,825,17066,17310)` (corruption / assert / dump) — real-time, page DBA lead
