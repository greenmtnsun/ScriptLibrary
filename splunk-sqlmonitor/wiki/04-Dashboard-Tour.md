# 04 — Dashboard Tour

Three dashboards, each shipped twice (SimpleXML and Dashboard Studio JSON).

## Executive — `sql_executive_dashboard.xml` / `_studio.json`

**Audience:** management, on-call lead, anyone who wants a fleet-wide health snapshot.

**Inputs:** Time range, Environment multiselect.

| Row | Panel | What it shows | What "bad" looks like |
|---|---|---|---|
| 1 | Servers In Scope | Count from inventory matching env filter | n/a — sanity |
| 1 | Servers Reporting | Distinct hosts that produced events in window | < Servers In Scope means UF/host issues |
| 1 | Silent Servers | Inventoried hosts with **zero** events | > 0 = investigate immediately |
| 1 | Service Stops/Crashes | Sum of SCM 7031/7034/7036 | > 0 in prod = page |
| 1 | Failed Logins (18456) | Auth failures | Bursts > 100 = security review |
| 1 | Backup Failures (3041) | Failed backups | > 0 = ticket |
| 1 | Job Failures (208) | SQL Agent step failures | > 5 = noisy or broken job |
| 2 | Health Matrix | Per-env Critical / Warning / Status | Any "DOWN/CRITICAL" cell |
| 2 | Severity Trend | Stacked column over time | Spikes correlate with deploys/incidents |
| 3 | Top 10 Hosts | Bar chart of noisiest hosts | Same host on top day after day = needs tuning |
| 3 | Failed Logins by Env | Line chart | Spike isolated to prod = real attack |
| 4 | AG State Changes | Table of role flips, suspends, resumes | Frequent role changes = failover instability |

## Operations — `sql_operations_dashboard.xml` / `_studio.json`

**Audience:** DBAs, on-call engineers responding to a page.

**Inputs:** Time range, Environment multiselect, Host dropdown (auto-populated from inventory).

| Row | Panel | What it shows |
|---|---|---|
| 1 | Service Control Events | SCM events filtered to SQL — start/stop/crash with action label |
| 1 | Failed Logins — Top Offending Accounts | login_user + client_ip parsed from Message |
| 2 | Severe Engine Errors | 824/825/9002/1105/17066/17310/17890 with human-readable issue |
| 2 | Slow I/O Warnings (833) | Per-host trend of long I/O |
| 3 | Backup Outcomes | Stacked success/failure timechart |
| 3 | Backup Failures by Host | Per-DB failure list |
| 4 | Agent Job Failures (208) | job_name + step_id parsed |
| 5 | AG Events | All AG-related EventIDs with role/cluster context |
| 6 | Custom Telemetry — Runaway Anomalies | Z-score table from 2001 events |
| 6 | Custom Telemetry — Stuck Sessions | Blocking detail from 1001 events |
| 7 | Raw Event Stream | Raw events for forensic reading |

## Security — `sql_security_dashboard.xml` / `_studio.json`

**Audience:** security operations, DBA leads.

**Inputs:** Time range, Environment multiselect, Business Hours start/end (default 7–19 local).

| Row | Panel | What it shows |
|---|---|---|
| 1 | KPIs | Failed login total, distinct attacking IPs, sa attempts, off-hours successes, hosts targeted |
| 2 | Top Attacking Source IPs | Sorted by attempt count |
| 2 | Top Targeted Accounts | Most-tried login_user values |
| 3 | Failure Reasons | Pie of 18456 sub-state reasons |
| 3 | Failed Login Trend by Env | Stacked timechart |
| 4 | Brute-Force Candidates | ≥10 fails in 5-min window from one IP |
| 4 | sa Login Activity | Every sa attempt — success or fail |
| 5 | Off-Hours Successful Logins | Requires SQL audit-success enabled |
| 6 | Failed Logins Heatmap | host × hour intensity map |

## Linking dashboards (drilldown)

Want a click in Exec to open Ops with the host pre-selected? Add to any host-bearing panel in `sql_executive_dashboard.xml`:

```xml
<drilldown>
  <link target="_blank">
    /app/&lt;APP&gt;/sql_operations_dashboard?form.host_tok=$row.host$&amp;form.tr.earliest=$tr.earliest$&amp;form.tr.latest=$tr.latest$
  </link>
</drilldown>
```

Replace `<APP>` with your actual app slug (e.g. `search` or `sql_fleet`). For Studio, use the visual drilldown editor — same effect.
