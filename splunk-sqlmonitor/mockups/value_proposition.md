# Value Proposition — SQL Server Fleet Monitoring in Splunk

> **The 30-second pitch:** We already pay for Splunk and we already forward Windows Event Logs from every SQL Server. Today, that data sits unused. This stack turns it into a one-glance fleet status, paged alerts on the four things that actually take production down, and a daily/weekly digest for leadership — using existing infrastructure. No new licenses, no new agents, no SQL DBA workload added.

---

## What's broken today (the "before")

| Pain | What it costs us |
|---|---|
| No single view of SQL fleet health across Dev/Test/Stage/Prod | Each DBA RDPs into hosts individually during incidents — 10–30 min added to MTTR |
| Outages discovered by users, not by us | Trust erosion with app teams; escalations land in leadership's inbox |
| Backup failures noticed days later | A failed nightly backup that nobody saw means a failed recovery on the day we need it |
| Brute-force / failed-login activity is invisible | Compliance gap; security can't answer "who is hammering our SQL boxes?" |
| No data to defend headcount or capacity decisions | Hard to argue for tier-1 attention to an environment with no metrics |

## What this delivers (the "after")

### Three dashboards

1. **Executive view** — one screen, fleet-wide. *Shown in the mockup.* For leadership and on-call lead.
2. **Operations view** — per-host deep dive. For the DBA actively responding to a page.
3. **Security view** — failed-login forensics, brute-force candidates, off-hours access, sa-account watchdog.

### Nine prioritized alerts (P1 = page, P2 = ticket, P3 = email)

| Tier | Alert | What it catches |
|---|---|---|
| **P1** | Service crash | SQL service died and didn't auto-recover |
| **P1** | Database corruption | Logical I/O error, failing disk, stack dump |
| **P1** | Log/data file full | A database is read-only RIGHT NOW |
| **P1** | AG suspended (prod) | Failover replica is no longer protecting prod |
| **P2** | Backup failure | Tonight's backup didn't complete |
| **P2** | Runaway batch job | Jobs running 5×+ longer than historical median |
| **P2** | Agent job step failure | Scheduled work didn't run |
| **P3** | Failed-login burst | Possible credential attack |
| **P3** | Silent server | A SQL host has stopped reporting |

### Four scheduled reports

- **Daily 7 a.m. exec digest** — emailed to leadership: yesterday's P1/P2/P3 counts per environment
- **Weekly fleet health** — Monday 6 a.m.: severity rollup, top noisy hosts, backup success rate
- **Daily backup coverage** — 6 a.m.: which hosts backed up, which didn't
- **Monthly trend** — 1st of month: failed logins, backups, jobs, anomalies vs. previous month

---

## Concrete scenarios (what would have changed)

| Past incident pattern | Without this stack | With this stack |
|---|---|---|
| Production SQL service crashed at 02:14, discovered by users at 07:45 | 5h 31m of downtime, mid-morning escalation | Page fires at 02:19 (next 5-min cycle), DBA on it at 02:25 — under 15 min impact |
| Nightly backup of `Reporting` DB has been failing for 6 days | Discovered when restoring after a page corruption — RPO = 7 days | Daily backup-coverage email day 1 → ticket → fixed before any data risk |
| 3,400 failed logins from 10.40.1.55 against `sqlprd04` over 48h | No one noticed until SecOps pulled audit logs | P3 fires at attempt #25 in 5 min; SecOps + DBA on the same alert |
| AG replica suspended after a network blip; failover protection silently gone | Discovered weeks later during DR test | P1 fires within 5 min; replica resumed before primary needed it |

---

## What it costs

| Item | Effort |
|---|---|
| New software licenses | **$0** — uses existing Splunk + UF |
| New agents on SQL hosts | **None** — UF is already there |
| DBA workload to maintain | One CSV (the server inventory) — updated when servers are built/decommissioned. ~5 min per change. |
| Splunk search-head capacity | Negligible at <200 hosts. (See FAQ for summary-indexing pattern at higher scale.) |
| Initial install | One person, one afternoon. Packaged as a `.spl` file: upload → done. |
| Ongoing maintenance | Quarterly review (1 hour) of alert volume + tuning. |

---

## Why this wasn't done already

It looks easy in retrospect. The reasons it hasn't been built:

- The data is there but **scattered** — three SourceNames, two log channels, named instances breaking obvious filters.
- The **inventory enrichment** (env / role / owner / tier per host) doesn't exist on the events themselves; it has to be joined in via a CSV.
- **Without a runbook**, alerts become noise; with a runbook, they become tools. We shipped the runbook (per-alert response, what to query, when to escalate).
- **Without throttling**, a flapping host pages 200×; with the right suppression keys, it pages once per 30 min and group-failures still surface.

The stack is opinionated about all four of those choices.

---

## Risks / honest caveats

| Limitation | Why |
|---|---|
| Can't see deadlocks | They live in SQL's system_health XE session, not the Windows Event Log. We monitor the symptoms (job timeouts, blocked sessions via the custom telemetry script) but not the deadlock graphs themselves. |
| Can't see slow queries / CPU / memory pressure live | Requires perfmon or DMV queries — neither is in scope here. The stack flags the *consequences* (memory paging events, I/O slow warnings) but not the cause. |
| Won't help with Azure SQL / RDS / Managed Instance | Those don't write to Windows Event Log. Path exists (Azure Diagnostic → Log Analytics → Splunk) but is out of scope for v1. |

These are real and we're upfront about them. Adding any of them is a separate project (DB Connect license, perfmon collection, Azure pipeline) — not a flaw of the current scope.

---

## Decision

> **What we're asking:** Approve the half-day install + 1 sprint to replace the mock inventory CSV with the real Dev/Test/Stage/Prod lists and wire two of the P1 alerts to PagerDuty.
>
> **Pilot scope:** Prod only, two alerts (Service Crash + Backup Failure). 30 days. If silence ratio < 95% (real-fire / total-fire), we tune; if it stays bad, we roll back. Zero residual cost.
