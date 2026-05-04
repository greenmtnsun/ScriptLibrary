/*===========================================================================
  01_VLF_Discovery.sql
  -------------------------------------------------------------------------
  Purpose : Scan every database on this instance and flag log/VLF issues
            that a DBA should investigate.
  Run as  : Member of sysadmin (or with VIEW SERVER STATE + VIEW ANY DEFINITION)
  Output  : One row per database with severity, issue, and recommended action.

  How to use across a farm:
    - Run this on each instance via a Central Management Server (CMS)
      multi-server query, or via PowerShell / dbatools (Invoke-DbaQuery)
      looping over your instance list.
    - Collect the results into a central table for triage.

  Thresholds (tweak to taste):
    - VLF_WARN     : 200   (start watching)
    - VLF_CRITICAL : 1000  (definitely fix)
    - LOG_USED_PCT_WARN : 80
===========================================================================*/

SET NOCOUNT ON;

DECLARE @VLF_WARN          int = 200;
DECLARE @VLF_CRITICAL      int = 1000;
DECLARE @LOG_USED_PCT_WARN int = 80;

IF OBJECT_ID('tempdb..#Findings') IS NOT NULL DROP TABLE #Findings;
CREATE TABLE #Findings (
    server_name           sysname        NOT NULL,
    database_name         sysname        NOT NULL,
    severity              varchar(10)    NOT NULL,  -- INFO / WARN / CRIT
    issue                 varchar(100)   NOT NULL,
    detail                nvarchar(2000) NULL,
    recommended_action    nvarchar(1000) NULL
);

IF OBJECT_ID('tempdb..#LogInfo') IS NOT NULL DROP TABLE #LogInfo;
CREATE TABLE #LogInfo (
    database_id      int            NOT NULL,
    database_name    sysname        NOT NULL,
    vlf_count        int            NULL,
    active_vlf_count int            NULL,
    log_size_mb      decimal(18,2)  NULL,
    log_used_mb      decimal(18,2)  NULL,
    log_used_pct     decimal(5,2)   NULL
);

/*-----------------------------------------------------------------------
  Collect per-database log + VLF metrics.
  sys.dm_db_log_info requires SQL Server 2016 SP2 / 2017+.
  sys.dm_db_log_space_usage requires SQL Server 2012+.
-----------------------------------------------------------------------*/
DECLARE @sql nvarchar(max), @dbid int, @dbname sysname;

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT database_id, name
    FROM   sys.databases
    WHERE  state_desc = 'ONLINE'
      AND  database_id <> 2;  -- skip tempdb (its log is recreated on restart)

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @dbid, @dbname;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'
            USE ' + QUOTENAME(@dbname) + N';
            INSERT INTO #LogInfo (database_id, database_name, vlf_count, active_vlf_count,
                                  log_size_mb, log_used_mb, log_used_pct)
            SELECT
                DB_ID(),
                DB_NAME(),
                (SELECT COUNT(*)        FROM sys.dm_db_log_info(DB_ID())),
                (SELECT COUNT(*)        FROM sys.dm_db_log_info(DB_ID()) WHERE vlf_active = 1),
                CAST(total_log_size_in_bytes / 1048576.0 AS decimal(18,2)),
                CAST(used_log_space_in_bytes  / 1048576.0 AS decimal(18,2)),
                CAST(used_log_space_in_percent AS decimal(5,2))
            FROM sys.dm_db_log_space_usage;';
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
        -- Skip databases we cannot query (offline mid-scan, restoring, etc.)
    END CATCH;

    FETCH NEXT FROM db_cur INTO @dbid, @dbname;
END;

CLOSE db_cur;
DEALLOCATE db_cur;

/*-----------------------------------------------------------------------
  Finding 1: High VLF count
-----------------------------------------------------------------------*/
INSERT INTO #Findings (server_name, database_name, severity, issue, detail, recommended_action)
SELECT
    @@SERVERNAME,
    li.database_name,
    CASE WHEN li.vlf_count >= @VLF_CRITICAL THEN 'CRIT' ELSE 'WARN' END,
    'High VLF count',
    CONCAT('VLF count = ', li.vlf_count,
           ' (active = ', li.active_vlf_count,
           '), log size = ', li.log_size_mb, ' MB'),
    'Back up log, shrink log file, then re-grow in deliberate chunks (e.g., 8 GB x N). See remediation script #1.'
FROM #LogInfo li
WHERE li.vlf_count >= @VLF_WARN;

/*-----------------------------------------------------------------------
  Finding 2: Log truncation blocked (the single most useful diagnostic)
-----------------------------------------------------------------------*/
INSERT INTO #Findings (server_name, database_name, severity, issue, detail, recommended_action)
SELECT
    @@SERVERNAME,
    d.name,
    CASE
        WHEN d.log_reuse_wait_desc IN ('ACTIVE_TRANSACTION','REPLICATION','AVAILABILITY_REPLICA',
                                       'DATABASE_MIRRORING','OLDEST_PAGE') THEN 'CRIT'
        WHEN d.log_reuse_wait_desc = 'LOG_BACKUP' THEN 'WARN'
        ELSE 'INFO'
    END,
    CONCAT('Log reuse blocked: ', d.log_reuse_wait_desc),
    CONCAT('Recovery model = ', d.recovery_model_desc,
           ', log_reuse_wait_desc = ', d.log_reuse_wait_desc),
    CASE d.log_reuse_wait_desc
        WHEN 'LOG_BACKUP'           THEN 'Take a log backup. If FULL recovery without backups, fix backup job. See remediation #2.'
        WHEN 'ACTIVE_TRANSACTION'   THEN 'Find and resolve long-running transaction. See remediation #3.'
        WHEN 'REPLICATION'          THEN 'Check log reader agent / CDC capture job health.'
        WHEN 'AVAILABILITY_REPLICA' THEN 'Check AG secondary replica connectivity and redo lag.'
        WHEN 'DATABASE_MIRRORING'   THEN 'Check mirroring partner connectivity.'
        WHEN 'OLDEST_PAGE'          THEN 'Run a manual CHECKPOINT.'
        ELSE 'Investigate.'
    END
FROM sys.databases d
WHERE d.state_desc = 'ONLINE'
  AND d.database_id <> 2
  AND d.log_reuse_wait_desc NOT IN ('NOTHING');

/*-----------------------------------------------------------------------
  Finding 3: Log file nearly full
-----------------------------------------------------------------------*/
INSERT INTO #Findings (server_name, database_name, severity, issue, detail, recommended_action)
SELECT
    @@SERVERNAME,
    li.database_name,
    'WARN',
    'Log file high utilization',
    CONCAT('Log used = ', li.log_used_pct, '% of ', li.log_size_mb, ' MB'),
    'Investigate growth cause; verify log backups; consider pre-sizing log larger.'
FROM #LogInfo li
WHERE li.log_used_pct >= @LOG_USED_PCT_WARN;

/*-----------------------------------------------------------------------
  Finding 4: Bad autogrowth settings on the log file
  (percentage growth, or fixed growth < 64 MB which causes VLF fragmentation)
-----------------------------------------------------------------------*/
INSERT INTO #Findings (server_name, database_name, severity, issue, detail, recommended_action)
SELECT
    @@SERVERNAME,
    DB_NAME(mf.database_id),
    'WARN',
    'Poor log autogrowth setting',
    CONCAT('Logical name = ', mf.name,
           ', growth = ', mf.growth,
           CASE WHEN mf.is_percent_growth = 1 THEN ' (percent)' ELSE ' (8 KB pages)' END,
           ', max_size = ', mf.max_size),
    'Set log autogrowth to a fixed size (e.g., 512 MB or 1 GB), not a percentage. See remediation #4.'
FROM sys.master_files mf
JOIN sys.databases    d ON d.database_id = mf.database_id
WHERE mf.type_desc = 'LOG'
  AND d.state_desc = 'ONLINE'
  AND mf.database_id <> 2
  AND (mf.is_percent_growth = 1
       OR (mf.is_percent_growth = 0 AND mf.growth < 8192));  -- < 64 MB in 8 KB pages

/*-----------------------------------------------------------------------
  Finding 5: FULL/BULK_LOGGED recovery model with no recent log backup
-----------------------------------------------------------------------*/
INSERT INTO #Findings (server_name, database_name, severity, issue, detail, recommended_action)
SELECT
    @@SERVERNAME,
    d.name,
    'CRIT',
    'No recent log backup',
    CONCAT('Recovery model = ', d.recovery_model_desc,
           ', last log backup = ',
           ISNULL(CONVERT(varchar(30), MAX(b.backup_finish_date), 120), 'NEVER')),
    'Configure log backups OR switch to SIMPLE recovery if PITR not required. See remediation #2.'
FROM sys.databases d
LEFT JOIN msdb.dbo.backupset b
       ON b.database_name = d.name
      AND b.type = 'L'   -- log backup
WHERE d.recovery_model_desc IN ('FULL','BULK_LOGGED')
  AND d.state_desc = 'ONLINE'
  AND d.name NOT IN ('master','model','msdb','tempdb')
GROUP BY d.name, d.recovery_model_desc
HAVING MAX(b.backup_finish_date) IS NULL
    OR MAX(b.backup_finish_date) < DATEADD(hour, -24, GETDATE());

/*-----------------------------------------------------------------------
  Final report
-----------------------------------------------------------------------*/
SELECT
    server_name,
    database_name,
    severity,
    issue,
    detail,
    recommended_action
FROM #Findings
ORDER BY
    CASE severity WHEN 'CRIT' THEN 1 WHEN 'WARN' THEN 2 ELSE 3 END,
    database_name,
    issue;

-- Also surface the raw VLF/log metrics for context
SELECT 'Raw metrics' AS section, * FROM #LogInfo ORDER BY vlf_count DESC;
