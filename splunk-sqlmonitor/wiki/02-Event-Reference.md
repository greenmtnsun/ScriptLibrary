# 02 — Event Reference

Every Windows EventID this stack reacts to, what it actually means, and where it surfaces.

## SQL Server engine — `SourceName: MSSQLSERVER` / `MSSQL$<inst>` (Application log)

| EventID | Meaning | Severity | Surfaced in |
|---:|---|---|---|
| 824 | Logical consistency I/O error (page checksum / torn page) | P1 / corruption | Ops, Alert: Corruption |
| 825 | I/O retry succeeded (failing disk indicator) | P1 / corruption | Ops, Alert: Corruption |
| 833 | I/O request taking longer than 15 seconds | P3 / disk-perf | Ops |
| 1105 | Could not allocate space — data file full | P1 / file-full | Ops, Alert: Log/Data File Full |
| 3014 | Backup completed successfully | info | Ops, Backup report |
| 3041 | Backup failed | P2 | Ops, Alert: Backup Failure, Backup report |
| 9002 | Transaction log full | P1 / file-full | Ops, Alert: Log/Data File Full |
| 17066 | Assertion failure (SQL bug or corruption) | P1 / corruption | Ops, Alert: Corruption |
| 17310 | User-mode scheduler stack dump | P1 / corruption | Ops, Alert: Corruption |
| 17890 | Significant memory paging detected | P2 / mem | Ops |
| 18452 | Login failed (untrusted domain) | P3 / auth | Security |
| 18453 | Login succeeded (only if "audit successful logins" is on) | info | Security |
| 18454 | Login succeeded — same as above for some versions | info | Security |
| 18456 | Login failed (state code in Message indicates reason) | P3 / auth | Security, Exec, Alert: Failed Login Burst |
| 1480 | AG role change (primary ↔ secondary) | P2 / AG | Exec, Ops |
| 35206 | AG connection timeout | P1 (prod) / AG | Ops, Alert: AG |
| 35264 | AG data movement suspended | P1 (prod) / AG | Ops, Alert: AG |
| 35265 | AG data movement resumed | info | Ops |
| 41131 | AG online | info | Ops |

## SQL Agent — `SourceName: SQLSERVERAGENT` / `SQLAgent$<inst>` (Application log)

| EventID | Meaning | Severity | Surfaced in |
|---:|---|---|---|
| 208 | Job step failed | P2 | Ops, Exec, Alert: Job Step Failure |
| 318 | SQL Agent service started/stopped | info | (not surfaced; redundant with SCM 7036) |

## Windows Service Control Manager — `SourceName: Service Control Manager` (System log)

These are filtered to only SQL services via Message text matching.

| EventID | Meaning | Severity | Surfaced in |
|---:|---|---|---|
| 7000 | Service failed to start | P1 | Ops |
| 7031 | Service terminated unexpectedly | P1 | Ops, Exec, Alert: Service Crash |
| 7034 | Service crashed | P1 | Ops, Exec, Alert: Service Crash |
| 7036 | Service entered Running / Stopped state | info | Ops |

## Custom telemetry — `SourceName: SQLAgentTelemetry` (Application log)

Emitted by `Invoke-TelemetryANDAnomoly.ps1`. Optional — only present where that script is deployed.

| EventID | Meaning | JSON payload fields |
|---:|---|---|
| 1001 | Stuck/blocked SQL Agent job session | State, SessionId, BlockedBy, WaitType, Program |
| 2001 | Runaway anomaly — Modified Z-score over threshold | State, JobName, CurrentDurationSeconds, HistoricalMedianSeconds, CalculatedMAD, ModifiedZScore, Threshold |
| 5000 | Telemetry script error | Message string |

## Sub-state codes for 18456 (commonly extracted via regex on Message)

| State | Meaning |
|---:|---|
| 2 | User ID not valid |
| 5 | Invalid userID |
| 6 | Tried Windows login on SQL-only server |
| 7 | Login disabled / wrong password |
| 8 | Wrong password |
| 9 | Invalid password format |
| 11 | Valid login but server access failure |
| 12 | Same as 11, login from non-admin |
| 16 | Default DB unavailable |
| 18 | Password must be changed |
| 38 | Failed to find database |
| 58 | SQL login when server is in Windows-auth-only mode |
| 102/103 | Azure AD authentication failure |

## What we deliberately do NOT monitor (and why)

| Signal | Why not |
|---|---|
| Deadlocks | Default destination is system_health XE session — not the Application log. Would need TF1222 (writes to ERRORLOG, which we can't read) or scripted ingestion. |
| Wait stats / CPU / memory pressure | Lives in DMVs / perfmon — neither is available. |
| Slow queries | Same — DMV / Query Store data, no path in. |
| Index health, missing indexes | DMV-only. |
| Blocking chains (live) | Available only via DMV. The custom telemetry script (1001) covers a narrow subset (blocked Agent sessions). |
| Disk space | Perfmon counter; no Application-log equivalent except 1105/9002 fallback. |
