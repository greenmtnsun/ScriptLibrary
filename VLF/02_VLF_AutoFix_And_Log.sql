/*===========================================================================
  02_VLF_AutoFix_And_Log.sql
  -------------------------------------------------------------------------
  Purpose : Scan every database on this instance. Auto-fix the obvious /
            zero-risk scenarios. Log everything else (and what we fixed)
            to the SQL Server error log AND the Windows Application
            event log via xp_logevent, for DBA review.

  Run as  : sysadmin (xp_logevent and ALTER DATABASE both require it)
  Schedule: SQL Agent job, every 15-60 minutes is reasonable.

  Event log filtering:
    All events written here use error number 60000.
    In Windows Event Viewer: Application log, Source = MSSQLSERVER,
    EventID = 60000. Filter by message text "VLFCHECK" to isolate.

  AUTO-FIX policy (only safe, reversible, non-disruptive actions):
     [FIX-1] Bad log autogrowth setting -> ALTER FILEGROWTH to 1024 MB fixed.
             Metadata-only change. Takes effect on next growth event.
     [FIX-2] log_reuse_wait_desc = OLDEST_PAGE -> issue CHECKPOINT.
             Always safe.

  LOG-ONLY (never auto-fixed - require DBA judgment):
     [LOG] High VLF count             -> needs shrink+regrow window
     [LOG] LOG_BACKUP wait            -> may need recovery model decision
     [LOG] ACTIVE_TRANSACTION         -> never auto-kill user sessions
     [LOG] REPLICATION/AG/MIRRORING   -> infrastructure issue
     [LOG] No recent log backup       -> backup strategy decision
     [LOG] Log file > N% full         -> capacity decision
===========================================================================*/

SET NOCOUNT ON;

DECLARE @VLF_WARN          int = 200;
DECLARE @VLF_CRITICAL      int = 1000;
DECLARE @LOG_USED_PCT_WARN int = 80;
DECLARE @EVENT_ID          int = 60000;        -- consistent ID for filtering
DECLARE @TAG               nvarchar(20) = N'VLFCHECK';

DECLARE @msg      nvarchar(2040);   -- xp_logevent max msg length
DECLARE @severity varchar(20);
DECLARE @sql      nvarchar(max);

/*-----------------------------------------------------------------------
  Helper: every log entry is prefixed with [VLFCHECK] [SEVERITY] @@SERVERNAME
  so the event log is greppable.
-----------------------------------------------------------------------*/

/*=======================================================================
  PHASE 1 -- COLLECT LOG / VLF METRICS PER DATABASE
=======================================================================*/
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

DECLARE @dbid int, @dbname sysname;

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT database_id, name
    FROM   sys.databases
    WHERE  state_desc = 'ONLINE'
      AND  database_id <> 2;   -- skip tempdb

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @dbid, @dbname;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'
            USE ' + QUOTENAME(@dbname) + N';
            INSERT INTO #LogInfo
            SELECT
                DB_ID(), DB_NAME(),
                (SELECT COUNT(*) FROM sys.dm_db_log_info(DB_ID())),
                (SELECT COUNT(*) FROM sys.dm_db_log_info(DB_ID()) WHERE vlf_active = 1),
                CAST(total_log_size_in_bytes  / 1048576.0 AS decimal(18,2)),
                CAST(used_log_space_in_bytes  / 1048576.0 AS decimal(18,2)),
                CAST(used_log_space_in_percent AS decimal(5,2))
            FROM sys.dm_db_log_space_usage;';
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
        SET @msg = N'[' + @TAG + N'] [WARNING] ' + @@SERVERNAME
                 + N' - Could not query log metrics for database '
                 + QUOTENAME(@dbname) + N'. Error: ' + ERROR_MESSAGE();
        EXEC xp_logevent @EVENT_ID, @msg, 'WARNING';
    END CATCH;

    FETCH NEXT FROM db_cur INTO @dbid, @dbname;
END;

CLOSE db_cur;
DEALLOCATE db_cur;


/*=======================================================================
  PHASE 2 -- AUTO-FIX [FIX-1]: Bad log autogrowth settings
  ---------------------------------------------------------------------
  Targets log files with: percent growth, OR fixed growth < 64 MB.
  Sets FILEGROWTH = 1024 MB (fixed). Metadata change only.
=======================================================================*/
IF OBJECT_ID('tempdb..#BadGrowth') IS NOT NULL DROP TABLE #BadGrowth;
CREATE TABLE #BadGrowth (
    database_name sysname,
    logical_name  sysname,
    old_growth    int,
    is_percent    bit
);

INSERT INTO #BadGrowth
SELECT
    DB_NAME(mf.database_id),
    mf.name,
    mf.growth,
    mf.is_percent_growth
FROM sys.master_files mf
JOIN sys.databases    d ON d.database_id = mf.database_id
WHERE mf.type_desc = 'LOG'
  AND d.state_desc = 'ONLINE'
  AND mf.database_id <> 2
  AND d.is_read_only = 0
  AND (mf.is_percent_growth = 1
       OR (mf.is_percent_growth = 0 AND mf.growth < 8192));   -- 8192 pages = 64 MB

DECLARE fix_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT database_name, logical_name, old_growth, is_percent FROM #BadGrowth;

DECLARE @fix_db sysname, @fix_file sysname, @old_growth int, @is_pct bit;
OPEN fix_cur;
FETCH NEXT FROM fix_cur INTO @fix_db, @fix_file, @old_growth, @is_pct;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'ALTER DATABASE ' + QUOTENAME(@fix_db)
                 + N' MODIFY FILE (NAME = ' + QUOTENAME(@fix_file, '''')
                 + N', FILEGROWTH = 1024MB);';
        EXEC sp_executesql @sql;

        SET @msg = N'[' + @TAG + N'] [INFO] ' + @@SERVERNAME
                 + N' - [FIX-1 APPLIED] Database ' + QUOTENAME(@fix_db)
                 + N' log file ' + QUOTENAME(@fix_file)
                 + N': autogrowth changed from '
                 + CAST(@old_growth AS nvarchar(20))
                 + CASE WHEN @is_pct = 1 THEN N' percent' ELSE N' (8KB pages)' END
                 + N' to 1024 MB fixed.';
        EXEC xp_logevent @EVENT_ID, @msg, 'INFORMATIONAL';
    END TRY
    BEGIN CATCH
        SET @msg = N'[' + @TAG + N'] [ERROR] ' + @@SERVERNAME
                 + N' - [FIX-1 FAILED] Database ' + QUOTENAME(@fix_db)
                 + N' log file ' + QUOTENAME(@fix_file)
                 + N'. Error: ' + ERROR_MESSAGE();
        EXEC xp_logevent @EVENT_ID, @msg, 'ERROR';
    END CATCH;

    FETCH NEXT FROM fix_cur INTO @fix_db, @fix_file, @old_growth, @is_pct;
END;
CLOSE fix_cur;
DEALLOCATE fix_cur;


/*=======================================================================
  PHASE 3 -- AUTO-FIX [FIX-2]: OLDEST_PAGE wait -> CHECKPOINT
=======================================================================*/
DECLARE chk_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases
    WHERE state_desc = 'ONLINE'
      AND database_id <> 2
      AND log_reuse_wait_desc = 'OLDEST_PAGE';

OPEN chk_cur;
FETCH NEXT FROM chk_cur INTO @dbname;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'USE ' + QUOTENAME(@dbname) + N'; CHECKPOINT;';
        EXEC sp_executesql @sql;

        SET @msg = N'[' + @TAG + N'] [INFO] ' + @@SERVERNAME
                 + N' - [FIX-2 APPLIED] Database ' + QUOTENAME(@dbname)
                 + N': issued CHECKPOINT to clear OLDEST_PAGE log reuse wait.';
        EXEC xp_logevent @EVENT_ID, @msg, 'INFORMATIONAL';
    END TRY
    BEGIN CATCH
        SET @msg = N'[' + @TAG + N'] [ERROR] ' + @@SERVERNAME
                 + N' - [FIX-2 FAILED] Database ' + QUOTENAME(@dbname)
                 + N'. Error: ' + ERROR_MESSAGE();
        EXEC xp_logevent @EVENT_ID, @msg, 'ERROR';
    END CATCH;

    FETCH NEXT FROM chk_cur INTO @dbname;
END;
CLOSE chk_cur;
DEALLOCATE chk_cur;


/*=======================================================================
  PHASE 4 -- LOG-ONLY findings (never auto-fixed)
=======================================================================*/

/* [LOG] High VLF count */
DECLARE log_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT database_name, vlf_count, active_vlf_count, log_size_mb
    FROM   #LogInfo
    WHERE  vlf_count >= @VLF_WARN;

DECLARE @vlf int, @avlf int, @logmb decimal(18,2);
OPEN log_cur;
FETCH NEXT FROM log_cur INTO @dbname, @vlf, @avlf, @logmb;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @severity = CASE WHEN @vlf >= @VLF_CRITICAL THEN 'ERROR' ELSE 'WARNING' END;
    SET @msg = N'[' + @TAG + N'] [' + @severity + N'] ' + @@SERVERNAME
             + N' - [DBA REVIEW] High VLF count on ' + QUOTENAME(@dbname)
             + N': vlf_count=' + CAST(@vlf AS nvarchar(20))
             + N', active=' + CAST(@avlf AS nvarchar(20))
             + N', log_size_mb=' + CAST(@logmb AS nvarchar(20))
             + N'. Action: schedule shrink+regrow of log in deliberate chunks.';
    EXEC xp_logevent @EVENT_ID, @msg, @severity;

    FETCH NEXT FROM log_cur INTO @dbname, @vlf, @avlf, @logmb;
END;
CLOSE log_cur;
DEALLOCATE log_cur;

/* [LOG] log_reuse_wait_desc problems (excluding OLDEST_PAGE which we fixed) */
DECLARE wait_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT name, log_reuse_wait_desc, recovery_model_desc
    FROM   sys.databases
    WHERE  state_desc = 'ONLINE'
      AND  database_id <> 2
      AND  log_reuse_wait_desc NOT IN ('NOTHING','OLDEST_PAGE');

DECLARE @wait_desc nvarchar(60), @rec_model nvarchar(60), @action nvarchar(400);
OPEN wait_cur;
FETCH NEXT FROM wait_cur INTO @dbname, @wait_desc, @rec_model;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @severity = CASE @wait_desc
        WHEN 'LOG_BACKUP' THEN 'WARNING'
        ELSE 'ERROR'
    END;

    SET @action = CASE @wait_desc
        WHEN 'LOG_BACKUP'           THEN N'Verify log backup job is running. If PITR not required, consider SIMPLE recovery.'
        WHEN 'ACTIVE_TRANSACTION'   THEN N'Find long-running tran via DBCC OPENTRAN / dm_tran_active_transactions.'
        WHEN 'REPLICATION'          THEN N'Check log reader agent / CDC capture job health.'
        WHEN 'AVAILABILITY_REPLICA' THEN N'Check AG secondary connectivity and redo lag.'
        WHEN 'DATABASE_MIRRORING'   THEN N'Check mirroring partner connectivity.'
        ELSE N'Investigate log_reuse_wait_desc.'
    END;

    SET @msg = N'[' + @TAG + N'] [' + @severity + N'] ' + @@SERVERNAME
             + N' - [DBA REVIEW] Log truncation blocked on ' + QUOTENAME(@dbname)
             + N': log_reuse_wait_desc=' + @wait_desc
             + N', recovery=' + @rec_model
             + N'. Action: ' + @action;
    EXEC xp_logevent @EVENT_ID, @msg, @severity;

    FETCH NEXT FROM wait_cur INTO @dbname, @wait_desc, @rec_model;
END;
CLOSE wait_cur;
DEALLOCATE wait_cur;

/* [LOG] Log file high utilization */
DECLARE util_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT database_name, log_used_pct, log_size_mb
    FROM   #LogInfo
    WHERE  log_used_pct >= @LOG_USED_PCT_WARN;

DECLARE @pct decimal(5,2);
OPEN util_cur;
FETCH NEXT FROM util_cur INTO @dbname, @pct, @logmb;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @msg = N'[' + @TAG + N'] [WARNING] ' + @@SERVERNAME
             + N' - [DBA REVIEW] Log file high utilization on ' + QUOTENAME(@dbname)
             + N': used_pct=' + CAST(@pct AS nvarchar(20))
             + N', size_mb=' + CAST(@logmb AS nvarchar(20))
             + N'. Action: investigate growth cause; verify log backups.';
    EXEC xp_logevent @EVENT_ID, @msg, 'WARNING';

    FETCH NEXT FROM util_cur INTO @dbname, @pct, @logmb;
END;
CLOSE util_cur;
DEALLOCATE util_cur;

/* [LOG] FULL/BULK_LOGGED with no log backup in last 24h */
DECLARE backup_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT d.name, d.recovery_model_desc, MAX(b.backup_finish_date)
    FROM   sys.databases d
    LEFT JOIN msdb.dbo.backupset b
           ON b.database_name = d.name AND b.type = 'L'
    WHERE  d.recovery_model_desc IN ('FULL','BULK_LOGGED')
      AND  d.state_desc = 'ONLINE'
      AND  d.name NOT IN ('master','model','msdb','tempdb')
    GROUP BY d.name, d.recovery_model_desc
    HAVING MAX(b.backup_finish_date) IS NULL
        OR MAX(b.backup_finish_date) < DATEADD(hour, -24, GETDATE());

DECLARE @last_backup datetime;
OPEN backup_cur;
FETCH NEXT FROM backup_cur INTO @dbname, @rec_model, @last_backup;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @msg = N'[' + @TAG + N'] [ERROR] ' + @@SERVERNAME
             + N' - [DBA REVIEW] No recent log backup on ' + QUOTENAME(@dbname)
             + N': recovery=' + @rec_model
             + N', last_log_backup='
             + ISNULL(CONVERT(nvarchar(30), @last_backup, 120), N'NEVER')
             + N'. Action: configure log backups OR switch to SIMPLE recovery.';
    EXEC xp_logevent @EVENT_ID, @msg, 'ERROR';

    FETCH NEXT FROM backup_cur INTO @dbname, @rec_model, @last_backup;
END;
CLOSE backup_cur;
DEALLOCATE backup_cur;


/*=======================================================================
  Heartbeat - confirms the job ran even when nothing was found
=======================================================================*/
SET @msg = N'[' + @TAG + N'] [INFO] ' + @@SERVERNAME
         + N' - VLF/log scan completed at '
         + CONVERT(nvarchar(30), GETDATE(), 120) + N'.';
EXEC xp_logevent @EVENT_ID, @msg, 'INFORMATIONAL';

GO
