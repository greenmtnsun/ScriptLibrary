# 05 — Alert Runbook

Per-alert response procedure for the on-call engineer. All alerts live in `savedsearches.conf`.

> **Naming:** `SQL - <tier> - <name>`. Tier is `P1` (page now), `P2` (ticket today), `P3` (informational).

---

## P1 — Service Crash or Unexpected Termination

**Trigger:** Windows SCM EventID 7031 or 7034 against an inventoried SQL host.

**What it means:** SQL Server (engine or Agent) terminated outside of an admin action.

**Immediate steps**
1. Identify the host from the alert payload. Check the **Operations** dashboard, host-filter to that host, last 1h.
2. RDP to the host (or use a remote PS session). Check `Get-Service` for `MSSQL*` / `SQLAgent*` state.
3. Check Application log for the **last** event before the crash — look for 17066, 17310, OOM, or `dump` keywords.
4. If clustered/AG: confirm failover succeeded (`Get-ClusterGroup` / `sys.dm_hadr_availability_replica_states`).
5. Restart the service if it didn't auto-restart. Verify databases came online (no `RECOVERY_PENDING`).
6. File an incident ticket with the dump file path (`SQLDump*.txt` in the LOG folder) for vendor review.

**Common causes**
- Memory exhaustion (check 17890 events leading up)
- Failing storage (check 824/825 events)
- SQL bug — search KB for the assert/dump signature

**Throttle:** 30 minutes per host. Multiple crashes inside that window = single alert; investigate via dashboard.

---

## P1 — Corruption or Stack Dump

**Trigger:** EventID 824, 825, 17066, or 17310.

**What it means:**
- 824 = checksum mismatch on a data page (corruption)
- 825 = I/O succeeded after retry (failing disk warning)
- 17066 = engine assert (likely SQL bug or environmental corruption)
- 17310 = SQL Server captured a stack dump (something serious happened)

**Immediate steps**
1. **Do not run REPAIR_ALLOW_DATA_LOSS reflexively.** Contact storage team first.
2. Identify the affected database from the Message: `database 'X', file 'Y', page (Z)`.
3. Run `DBCC CHECKDB('<db>') WITH NO_INFOMSGS` against a snapshot or restored copy — never against the live DB on a hot server.
4. If 825: open a storage ticket — drive is degrading.
5. If 17066/17310: collect the SQLDump*.{txt,mdmp} from the LOG folder. Open vendor case.
6. Validate latest good backup chain — you may need it.

**Throttle:** 1 hour per host+EventCode.

---

## P1 — Log or Data File Full

**Trigger:** EventID 9002 (transaction log full) or 1105 (data file full).

**What it means:** A database is now read-only or aborting transactions for that DB.

**Immediate steps**
1. From alert payload note `host` and `db` (regex-extracted from Message).
2. Connect to the instance. Identify which file is full:
   ```sql
   SELECT name, size/128.0 AS size_mb, max_size/128.0 AS max_mb, growth
   FROM sys.master_files
   WHERE database_id = DB_ID('<db>');
   ```
3. **For 9002 (log full):**
   - If recovery model = FULL: take a log backup. That frees the VLFs.
   - If SIMPLE: check for active long transaction blocking truncation: `SELECT * FROM sys.dm_tran_database_transactions`.
   - Last resort temporary: `ALTER DATABASE <db> MODIFY FILE (NAME=<log>, MAXSIZE=<higher>)`.
4. **For 1105 (data file full):**
   - Verify drive space: `Get-PSDrive`.
   - Add a file or grow the existing file: `ALTER DATABASE <db> MODIFY FILE (NAME=<data>, SIZE=<larger>)`.
5. Once unblocked, root cause: bloated log? long transaction? autogrowth misconfigured? capacity planning?

**Throttle:** 30 minutes per host+db.

---

## P1 — Availability Group Suspended or Connection Timeout (prod only)

**Trigger:** EventID 35264 (suspended) or 35206 (connection timeout) on a prod-tagged host.

**Immediate steps**
1. From the **Operations** dashboard, AG events panel, scope to that AG cluster, last 4h.
2. Check replica state:
   ```sql
   SELECT ar.replica_server_name, drs.synchronization_state_desc,
          drs.synchronization_health_desc, drs.suspend_reason_desc
   FROM sys.dm_hadr_database_replica_states drs
   JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id;
   ```
3. If suspended: identify reason (`suspend_reason_desc`). Common: log full on secondary, network partition, manual.
4. Resume only after fixing the cause:
   ```sql
   ALTER DATABASE <db> SET HADR RESUME;
   ```
5. If connection timeout persistent: check inter-node network, Endpoint state, firewall rules between nodes.

**Throttle:** 30 minutes per AG+host.

---

## P2 — Backup Failure

**Trigger:** EventID 3041.

**Immediate steps**
1. Check **Operations** → "Backup Failures by Host" panel.
2. RDP/connect to the host. Check `msdb.dbo.sysjobhistory` for the failing backup job's last run details.
3. Common causes:
   - Backup target full (network share, Azure Blob)
   - Credential expired (SQL Server Credential / SAS token)
   - Long-running backup colliding with maintenance window
4. Re-run the backup manually to confirm the fix:
   ```sql
   BACKUP DATABASE [<db>] TO DISK = '<path>' WITH COMPRESSION, CHECKSUM;
   ```
5. If recurring on the same DB: add to the daily backup coverage report's exception list and open a remediation ticket.

**Throttle:** 2 hours per host+db.

---

## P2 — Runaway Agent Job (Modified Z ≥ 5)

**Trigger:** Custom telemetry EventID 2001 with `ModifiedZScore >= 5`.

**Immediate steps**
1. Confirm via **Operations** → "Custom Telemetry — Runaway Job Anomalies" — current vs historical median.
2. If `Current >> Median` (e.g. 4× median): connect and investigate live:
   ```sql
   SELECT session_id, blocking_session_id, wait_type, wait_time, status, command, text
   FROM sys.dm_exec_requests r
   CROSS APPLY sys.dm_exec_sql_text(r.sql_handle)
   WHERE program_name LIKE 'SQLAgent%';
   ```
3. Cross-reference EventID 1001 (stuck session) on the same host — same root cause likely.
4. Decide: kill the spid, let it run, or fix the underlying blocker.
5. After resolution, validate next scheduled run completes within MAD window.

**Throttle:** 1 hour per host+job.

---

## P2 — SQL Agent Job Step Failure

**Trigger:** EventID 208.

**Immediate steps**
1. Get the job name + step from the alert (regex-parsed).
2. `SELECT * FROM msdb.dbo.sysjobhistory WHERE job_id = (SELECT job_id FROM msdb.dbo.sysjobs WHERE name = '<job>') ORDER BY run_date DESC, run_time DESC`.
3. Read step output / `message` column for the actual error.
4. Common: permission, connectivity, locking, missing object after deploy.
5. Re-run the step manually to confirm the fix.

**Throttle:** 30 minutes per host+job.

---

## P3 — Failed Login Burst

**Trigger:** ≥25 18456 events from a single client IP within 15 minutes against any inventoried host.

**Triage**
1. **Security** dashboard → "Brute-Force Candidates" + "Top Attacking Source IPs".
2. Check the source IP — is it a known app server with a stale password? Or external?
3. If internal/known: contact owning team to fix the credential.
4. If external: confirm with networking that this IP should reach SQL at all (it usually shouldn't). Block at firewall.
5. Open security ticket; confirm no successful login from that IP follows.

**Throttle:** 1 hour per host+IP.

---

## P3 — Silent Inventoried Server

**Trigger:** A host in `sql_inventory_lookup` produced zero engine/agent/service/telemetry events in the last 30 minutes.

**Triage**
1. Is the host up? Ping, RDP, check uptime.
2. Is the Universal Forwarder running? `Get-Service SplunkForwarder`.
3. Check forwarder logs for indexer connection issues: `splunkd.log`.
4. Is SQL itself running? `Get-Service MSSQL*`.
5. Is the host genuinely idle (e.g. dev box during off-hours)? If so, mark as expected and consider `tier=3` exempting from this alert.

**Throttle:** 2 hours per host.
