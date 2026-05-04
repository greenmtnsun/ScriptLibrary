# VLF Health Kit

Operational tooling for monitoring and remediating Virtual Log File (VLF) and transaction-log issues across a fleet of SQL Server instances.

The kit auto-fixes the safe scenarios (bad log autogrowth settings, `OLDEST_PAGE` checkpoint waits) and writes everything else to the SQL Server error log and Windows Application event log via `xp_logevent` for DBA review. It is designed to be deployed identically to every instance and re-run at any time without side effects.

## Contents

```
VLF/
├── README.md                      (this file)
├── 01_VLF_Discovery.sql           One-shot read-only triage report
├── 02_VLF_AutoFix_And_Log.sql     Standalone scan + autofix + event-log writer
├── 03_VLF_Deploy_Job.sql          Idempotent SQL Agent job deployment
├── 04_VLF_Drop_Job.sql            Idempotent SQL Agent job removal
└── notes/
    ├── VLF_Wiki.md                Conceptual reference - what VLFs are, how they behave
    └── VLF_HowTo.md               Operational how-to - deployment, triage playbooks
```

## Requirements

- SQL Server 2016 SP2 / 2017 or later (uses `sys.dm_db_log_info`).
- `sysadmin` to deploy. The runtime job runs under `sa`.
- `xp_logevent` enabled (default).

## Quickstart

**To deploy on a single instance:**

Run `03_VLF_Deploy_Job.sql` against the target instance. It creates the stored procedure `msdb.dbo.usp_VLFHealthCheck` and the SQL Agent job `DBA - VLF Health Check`, scheduled every 30 minutes. Re-running is safe — it drops and recreates cleanly.

**To deploy across the fleet:**

```powershell
$instances = Get-Content .\sql_instances.txt
$body      = Get-Content -Raw .\03_VLF_Deploy_Job.sql
foreach ($i in $instances) {
    Invoke-DbaQuery -SqlInstance $i -Query $body -EnableException
}
```

**To remove from any instance:**

Run `04_VLF_Drop_Job.sql`. Stops the job if running, drops the job and proc cleanly, preserves history.

**To investigate without deploying:**

Run `01_VLF_Discovery.sql` interactively. Read-only. Returns a triage table.

## Event Log Output

All entries use Windows Application event ID `60000`, source `MSSQLSERVER`, prefixed `[VLFCHECK]`. Filter on the prefix to isolate. Severities are `INFO` (heartbeat, applied autofixes), `WARNING` (review when convenient), `ERROR` (review now).

`[FIX-1 APPLIED]` / `[FIX-2 APPLIED]` are audit entries — the kit changed something. `[DBA REVIEW]` entries are findings requiring human judgment; the per-finding triage playbooks are in `notes/VLF_HowTo.md` section 7.

## Tuning

Default thresholds (`@VLF_WARN = 200`, `@VLF_CRITICAL = 1000`, `@LOG_USED_PCT_WARN = 80`, `@AutoFixGrowthMB = 1024`) are parameters on `usp_VLFHealthCheck`. To tune per-instance, edit the job step's command from `EXEC msdb.dbo.usp_VLFHealthCheck;` to e.g. `EXEC msdb.dbo.usp_VLFHealthCheck @VLF_WARN = 500, @AutoFixGrowthMB = 4096;`.

## Documentation

- **`notes/VLF_Wiki.md`** — what VLFs are, what controls them, the `log_reuse_wait_desc` reference, common pathologies, full remediation procedures.
- **`notes/VLF_HowTo.md`** — deployment patterns, event log integration, triage playbooks for every `[DBA REVIEW]` event the kit can emit.

## License

Internal use. Adapt to your environment as needed.
