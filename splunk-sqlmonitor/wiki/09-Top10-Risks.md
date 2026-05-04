# 09 — Top 10 Things That Could Go Wrong (and How to Fix Them)

Strategic risks to the *whole* stack — the kind of thing that quietly makes your dashboards lie or your alerts go silent for weeks before anyone notices. Use this as a quarterly review checklist.

> **Companion page:** `07-Troubleshooting.md` is reactive (symptom you can see today). This page is preventative (failure modes that hide).

---

## #1 — Inventory drift

**Risk.** A new SQL host is provisioned, never added to `sql_inventory.csv`. It's invisible to every dashboard and every alert, indefinitely. Or a host is decommissioned but the CSV still lists it — Silent Server alert fires forever and people learn to ignore it.

**Symptom.** "Why didn't we see X go down?" or persistent unresolved silent-server alerts.

**Detection.** Quarterly diff inventory CSV vs. authoritative source (CMDB, ServiceNow, Terraform state, AD computer objects matching `SQL*`). Splunk-side detection:
```spl
(eventtype=sql_engine_events OR eventtype=sql_agent_events) earliest=-7d
| eval host=lower(coalesce(ComputerName,host))
| stats count by host
| join type=outer host [ | inputlookup sql_inventory_lookup | fields host | eval inventoried=1 ]
| where isnull(inventoried)
```
That returns hosts producing SQL events but missing from the CSV.

**Fix.**
- Make CSV updates part of the SQL Server build / decommission runbook (gate the change with a checklist).
- Schedule the diff search above as a weekly P3 alert.
- Optionally automate: pull the CMDB list nightly and write a candidate CSV; humans diff/approve.

---

## #2 — Universal Forwarder silently dies on a host

**Risk.** The UF service stops, crashes, or loses indexer connectivity on one or more hosts. Splunk simply stops receiving events from those hosts. To the dashboards, "no events" looks the same as "all healthy". Real outages will not generate alerts because the alert condition (event > 0) is never met.

**Symptom.** A real production crash happens but no P1 fired.

**Detection.** This is exactly what the **`SQL - P3 - Silent Inventoried Server`** alert is for. But also:
```spl
| metadata type=hosts index=*
| where now()-recentTime > 1800
| join host [ | inputlookup sql_inventory_lookup ]
```

**Fix.**
- Keep the Silent Server alert enabled.
- On every SQL host, add a simple Windows Scheduled Task that writes a heartbeat event every 5 minutes (e.g. `eventcreate /T INFORMATION /SO SQLHeartbeat /ID 1 /D heartbeat`). Then alert on "no heartbeat in 15m" instead of "no SQL event in 30m" — much tighter signal.
- Monitor the UF itself via `splunkforwarder` Windows service alerts.

---

## #3 — Host name mismatch (the silent join killer)

**Risk.** Inventory has `SQLPRD01`. Events arrive with `ComputerName=SQLPRD01.corp.local`. The lookup misses, `env` is null, the `where isnotnull(env)` clause silently drops every event. Dashboards look empty, alerts never fire, no error is thrown anywhere.

**Symptom.** Dashboards empty even though `index=...` clearly has data.

**Detection.**
```spl
(eventtype=sql_engine_events OR eventtype=sql_agent_events) earliest=-1h
| eval host=lower(coalesce(ComputerName,host))
| lookup sql_inventory_lookup host OUTPUT env
| stats count(eval(isnull(env))) as unmatched, count(eval(isnotnull(env))) as matched
```
If `unmatched > 0`: you have drift.

**Fix.**
- Standardise the CSV to whichever value (short or FQDN) lands consistently. The dashboards already lowercase via `coalesce`.
- Add the detection query above as a weekly P3 alert.
- If both forms occur in the wild, add both rows to the CSV (one per host), pointing to the same env/role/owner.

---

## #4 — Microsoft changes the Message text and regexes break silently

**Risk.** A SQL Server CU/version change tweaks the error wording. Our regex extracting `login_user` or `client_ip` returns null for every new event. Dashboards still render — just with blank columns. Brute-force alert never fires because IP grouping is null+null+null = "1 IP with millions of attempts".

**Symptom.** "(unparsed)" dominates the Failure Reasons pie. login_user / client_ip columns blank.

**Detection.** Monthly:
```spl
eventtype=sql_engine_events EventCode=18456 earliest=-7d
| rex field=Message "(?i)Login failed for user '(?<u>[^']+)'"
| rex field=Message "(?i)CLIENT:\s*\[?(?<ip>[0-9a-fA-F\.\:]+)\]?"
| stats count(u) as parsed, count as total
| eval parse_pct=round(100*parsed/total,1)
```
Below ~95% means a regex is degrading.

**Fix.**
- Look at 5 raw `_raw` samples and adjust the `rex` in the dashboard's base search.
- Make this part of the SQL CU/upgrade test plan: smoke-test the dashboard within 24h of an instance upgrade.

---

## #5 — Eventtype misses a new SQL instance naming pattern

**Risk.** A new named instance comes up as `MSSQL$ANALYTICS`. The eventtype's wildcard `MSSQL$*` *should* match it — but if someone "tightened" the eventtype to `SourceName=MSSQLSERVER OR SourceName="MSSQL$INST1"`, the new instance is invisible.

**Symptom.** New instance host shows up in inventory but `Servers Reporting` doesn't include it.

**Detection.**
```spl
sourcetype="WinEventLog:Application" SourceName=MSSQL* earliest=-1h
| stats count by SourceName
```
Cross-check the SourceName list against what the eventtype matches.

**Fix.** Keep the eventtype broad (`MSSQL$*`) — never list specific instances. If you must whitelist, maintain a separate `sql_instances.csv` lookup and review quarterly.

---

## #6 — Alarm fatigue

**Risk.** One P2 alert (typically Job Step Failure or Failed Login Burst) is misconfigured and pages 200×/day. People mute the channel. Two weeks later a real P1 fires and is missed because the channel is muted.

**Symptom.** Slack/PagerDuty channels with persistent unread counts. Engineers volunteering to "be excluded" from rotations.

**Detection.**
```spl
index=_audit action=alert_fired earliest=-7d
| stats count by ss_name
| sort - count
```
Any alert > 100/week is a candidate for tuning. Any alert > 500/week is broken.

**Fix.**
- See `06-Tuning-Guide.md`.
- Establish an SLO on alert noise: "no alert fires > N times per week without remediation". Review weekly.
- For known-noisy categories (job failures), build a per-job exception lookup with `expires` dates so suppression doesn't become permanent by accident.

---

## #7 — Throttle suppressing fleet-wide outages

**Risk.** All P1 alerts use `alert.suppress.fields = host`. If one host crashes, you get one alert per 30 min — correct. But if a *shared* failure (network partition, AD outage, storage controller failure) takes down 40 hosts simultaneously, you get one alert per host within seconds — *and then 30 minutes of silence* even if the situation worsens.

**Symptom.** Major incidents where the alert volume drops off after the first burst, masking ongoing impact.

**Detection.** Post-incident review: did the alert pattern reflect the blast radius?

**Fix.** Add a fleet-wide companion alert:
```
[SQL - P1 - Multi-host Service Crash]
search = eventtype=sql_service_events EventCode IN (7031,7034) | ... | stats dc(host) as hosts | where hosts >= 5
alert.suppress.fields = (none — alert globally)
alert.suppress.period = 5m
```
Pages once when ≥5 hosts crash in the same window. Catches infrastructure-class events that per-host throttling would obscure.

---

## #8 — Index retention shorter than alert lookback

**Risk.** Alert lookback is 24h but the index's retention/freezing schedule rolls events out at 12h (e.g. cost-saving on a noisy environment index). Half the alert's window has no data → false negatives or correct alerts that look like they're under-counting.

**Symptom.** Daily backup report claims success counts that are obviously too low. Alerts seem to "miss" events you can confirm happened.

**Detection.**
```spl
| dbinspect index=<your_index>
| stats min(earliestTime) as oldest_data
| eval age_hours=round((now()-strptime(oldest_data,"%FT%T"))/3600,1)
```
If `age_hours < 24` and your alerts use 24h lookback, you have a problem.

**Fix.**
- Match alert lookback to actual hot/warm retention. Either lengthen retention or shorten lookback (but never shorter than your alert's cron).
- Use summary indexing for historical reports — see `08-FAQ.md`.

---

## #9 — Time skew between SQL hosts and indexers

**Risk.** A SQL host's clock drifts (NTP fails, VM time-sync misbehaves). Events arrive with `_time` values in the future or several minutes in the past. They land in the wrong time bucket, miss your alert window entirely, and appear out of order in the raw stream.

**Symptom.** Timecharts show suspicious gaps. Alerts that *should* have fired don't, then fire later when the events catch up.

**Detection.**
```spl
sourcetype="WinEventLog:Application" earliest=-1h
| eval skew=_indextime-_time
| stats avg(skew) as avg_skew_sec, max(skew) as max_skew by host
| where abs(avg_skew_sec) > 60
```

**Fix.**
- Standardise NTP across the fleet (`w32tm /resync` for ad hoc).
- For VMs: confirm the host-time sync setting (Hyper-V time integration, VMware Tools time sync). Best practice: disable hypervisor time sync, use Domain NTP exclusively.
- Add the detection query as a weekly P3 alert.

---

## #10 — Search head capacity exhaustion

**Risk.** Every alert has `cron_schedule = */5 * * * *`. With 9 alerts × every 5 min × N concurrent dashboards × M users, the SH's concurrent search slots saturate. Searches start queueing, alerts run late, dashboards spin. In a really bad case, scheduled searches start being skipped (`splunkd.log` shows `skipped reason=skipped`).

**Symptom.** Alert delays of 15+ minutes. Dashboards take 30+ seconds to load. `index=_internal sourcetype=scheduler status=skipped` returns rows.

**Detection.**
```spl
index=_internal sourcetype=scheduler app=<APP> earliest=-24h
| stats count(eval(status="success")) as ok, count(eval(status="skipped")) as skipped, count(eval(status="continued")) as backlogged by savedsearch_name
| where skipped > 0 OR backlogged > 0
```

**Fix.**
- Stagger cron schedules: instead of all P1s on `*/5 * * * *`, spread them: `1/5 * * * *`, `2/5 * * * *`, `3/5 * * * *`.
- Move the "noisy" base searches to summary indexes (compute once every 5m, alert reads from summary).
- Increase SH search concurrency (`limits.conf [search] base_max_searches`) — capacity planning question.
- Convert dashboards to use `<search id="base"> ... </search>` with `<search base="base">` panels (already done in our SimpleXML; confirm all panels reference the base, not their own queries).

---

## Bonus — silent dependency drift

These don't make the top 10, but they bite eventually:

- **Splunk version upgrade** changes a default in `eventtypes.conf` parsing (rare but happened in 9.x→9.4)
- **Custom telemetry script** stops running because the gMSA password expired or dbatools module wasn't updated after a Powershell upgrade
- **CSV gets edited via Excel**, which silently re-encodes UTF-8 BOM and changes line endings → lookup mysteriously stops matching
- **App permissions** change after an admin migrates objects between apps → the lookup is suddenly only visible to one app
- **Splunk role permissions** rolled back after a security review → dashboards work for admins, fail for everyone else (test with a non-admin account quarterly)
