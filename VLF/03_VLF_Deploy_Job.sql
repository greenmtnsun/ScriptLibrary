/*===========================================================================
  03_VLF_Deploy_Job.sql
  -------------------------------------------------------------------------
  Idempotent deployment of the VLF Health Check.

  Creates (or recreates):
    - Stored procedure  : msdb.dbo.usp_VLFHealthCheck
    - SQL Agent job     : DBA - VLF Health Check
    - Job schedule      : Every 30 minutes

  Safe to run repeatedly on any instance. If the job or proc already exists,
  they are dropped and recreated cleanly. No state is preserved across runs
  (the job's run history in msdb.dbo.sysjobhistory IS preserved by default
  unless you explicitly purge it).

  Run as : sysadmin
  Target : Any SQL Server 2016 SP2+ / 2017+ instance
===========================================================================*/

SET NOCOUNT ON;

DECLARE @JobName     sysname = N'DBA - VLF Health Check';
DECLARE @ProcName    sysname = N'usp_VLFHealthCheck';
DECLARE @ScheduleNm  sysname = N'VLF Health Check - Every 30 min';
DECLARE @CategoryNm  sysname = N'Database Maintenance';
DECLARE @OwnerLogin  sysname = N'sa';

PRINT '=== VLF Health Check deployment starting on ' + @@SERVERNAME + ' ===';

/*=======================================================================
  STEP 1 -- Drop existing job (if present)
=======================================================================*/
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName)
BEGIN
    PRINT 'Dropping existing job: ' + @JobName;
    EXEC msdb.dbo.sp_delete_job
        @job_name              = @JobName,
        @delete_unused_schedule = 1;
END
ELSE
    PRINT 'No existing job to drop.';

/*=======================================================================
  STEP 2 -- Drop existing stored procedure (if present)
=======================================================================*/
IF OBJECT_ID('msdb.dbo.usp_VLFHealthCheck') IS NOT NULL
BEGIN
    PRINT 'Dropping existing procedure: msdb.dbo.usp_VLFHealthCheck';
    EXEC msdb.dbo.sp_executesql N'DROP PROCEDURE dbo.usp_VLFHealthCheck;';
END
ELSE
    PRINT 'No existing procedure to drop.';

/*=======================================================================
  STEP 3 -- Create the stored procedure
=======================================================================*/
PRINT 'Creating procedure: msdb.dbo.usp_VLFHealthCheck';

EXEC msdb.dbo.sp_executesql N'
CREATE PROCEDURE dbo.usp_VLFHealthCheck
    @VLF_WARN          int = 200,
    @VLF_CRITICAL      int = 1000,
    @LOG_USED_PCT_WARN int = 80,
    @AutoFixGrowthMB   int = 1024
AS
/*-----------------------------------------------------------------------
  VLF Health Check - scans every online user database, auto-fixes safe
  scenarios (bad log autogrowth, OLDEST_PAGE waits), and writes all
  findings to the SQL Server error log AND the Windows Application
  event log via xp_logevent (event ID 60000, tag [VLFCHECK]).

  See VLF_Wiki.md and VLF_HowTo.md for context.
-----------------------------------------------------------------------*/
BEGIN
    SET NOCOUNT ON;

    DECLARE @EVENT_ID int          = 60000;
    DECLARE @TAG      nvarchar(20) = N''VLFCHECK'';
    DECLARE @msg      nvarchar(2040);
    DECLARE @severity varchar(20);
    DECLARE @sql      nvarchar(max);
    DECLARE @dbid     int;
    DECLARE @dbname   sysname;

    /*-- Phase 1: collect log/VLF metrics ---------------------------*/
    IF OBJECT_ID(''tempdb..#LogInfo'') IS NOT NULL DROP TABLE #LogInfo;
    CREATE TABLE #LogInfo (
        database_id      int           NOT NULL,
        database_name    sysname       NOT NULL,
        vlf_count        int           NULL,
        active_vlf_count int           NULL,
        log_size_mb      decimal(18,2) NULL,
        log_used_mb      decimal(18,2) NULL,
        log_used_pct     decimal(5,2)  NULL
    );

    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT database_id, name FROM sys.databases
        WHERE state_desc = ''ONLINE'' AND database_id <> 2;

    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @dbid, @dbname;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @sql = N''
                USE '' + QUOTENAME(@dbname) + N'';
                INSERT INTO #LogInfo
                SELECT DB_ID(), DB_NAME(),
                       (SELECT COUNT(*) FROM sys.dm_db_log_info(DB_ID())),
                       (SELECT COUNT(*) FROM sys.dm_db_log_info(DB_ID()) WHERE vlf_active = 1),
                       CAST(total_log_size_in_bytes / 1048576.0 AS decimal(18,2)),
                       CAST(used_log_space_in_bytes  / 1048576.0 AS decimal(18,2)),
                       CAST(used_log_space_in_percent AS decimal(5,2))
                FROM sys.dm_db_log_space_usage;'';
            EXEC sp_executesql @sql;
        END TRY
        BEGIN CATCH
            SET @msg = N''['' + @TAG + N''] [WARNING] '' + @@SERVERNAME
                     + N'' - Could not query log metrics for '' + QUOTENAME(@dbname)
                     + N''. Error: '' + ERROR_MESSAGE();
            EXEC xp_logevent @EVENT_ID, @msg, ''WARNING'';
        END CATCH;
        FETCH NEXT FROM db_cur INTO @dbid, @dbname;
    END;
    CLOSE db_cur; DEALLOCATE db_cur;

    /*-- Phase 2: AUTO-FIX bad log autogrowth -----------------------*/
    DECLARE @fix_db sysname, @fix_file sysname, @old_growth int, @is_pct bit;
    DECLARE @growth_pages int = @AutoFixGrowthMB * 128;  -- MB -> 8KB pages

    DECLARE fix_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT DB_NAME(mf.database_id), mf.name, mf.growth, mf.is_percent_growth
        FROM   sys.master_files mf
        JOIN   sys.databases    d ON d.database_id = mf.database_id
        WHERE  mf.type_desc = ''LOG''
          AND  d.state_desc = ''ONLINE''
          AND  mf.database_id <> 2
          AND  d.is_read_only = 0
          AND (mf.is_percent_growth = 1
               OR (mf.is_percent_growth = 0 AND mf.growth < 8192));

    OPEN fix_cur;
    FETCH NEXT FROM fix_cur INTO @fix_db, @fix_file, @old_growth, @is_pct;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @sql = N''ALTER DATABASE '' + QUOTENAME(@fix_db)
                     + N'' MODIFY FILE (NAME = '' + QUOTENAME(@fix_file, ''"''''"'')
                     + N'', FILEGROWTH = '' + CAST(@AutoFixGrowthMB AS nvarchar(20))
                     + N''MB);'';
            EXEC sp_executesql @sql;
            SET @msg = N''['' + @TAG + N''] [INFO] '' + @@SERVERNAME
                     + N'' - [FIX-1 APPLIED] '' + QUOTENAME(@fix_db)
                     + N'' log '' + QUOTENAME(@fix_file)
                     + N'': autogrowth changed from '' + CAST(@old_growth AS nvarchar(20))
                     + CASE WHEN @is_pct = 1 THEN N'' percent'' ELSE N'' (8KB pages)'' END
                     + N'' to '' + CAST(@AutoFixGrowthMB AS nvarchar(20)) + N'' MB fixed.'';
            EXEC xp_logevent @EVENT_ID, @msg, ''INFORMATIONAL'';
        END TRY
        BEGIN CATCH
            SET @msg = N''['' + @TAG + N''] [ERROR] '' + @@SERVERNAME
                     + N'' - [FIX-1 FAILED] '' + QUOTENAME(@fix_db)
                     + N'' log '' + QUOTENAME(@fix_file)
                     + N''. Error: '' + ERROR_MESSAGE();
            EXEC xp_logevent @EVENT_ID, @msg, ''ERROR'';
        END CATCH;
        FETCH NEXT FROM fix_cur INTO @fix_db, @fix_file, @old_growth, @is_pct;
    END;
    CLOSE fix_cur; DEALLOCATE fix_cur;

    /*-- Phase 3: AUTO-FIX OLDEST_PAGE -> CHECKPOINT ----------------*/
    DECLARE chk_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE state_desc = ''ONLINE'' AND database_id <> 2
          AND log_reuse_wait_desc = ''OLDEST_PAGE'';

    OPEN chk_cur;
    FETCH NEXT FROM chk_cur INTO @dbname;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @sql = N''USE '' + QUOTENAME(@dbname) + N''; CHECKPOINT;'';
            EXEC sp_executesql @sql;
            SET @msg = N''['' + @TAG + N''] [INFO] '' + @@SERVERNAME
                     + N'' - [FIX-2 APPLIED] '' + QUOTENAME(@dbname)
                     + N'': CHECKPOINT issued to clear OLDEST_PAGE wait.'';
            EXEC xp_logevent @EVENT_ID, @msg, ''INFORMATIONAL'';
        END TRY
        BEGIN CATCH
            SET @msg = N''['' + @TAG + N''] [ERROR] '' + @@SERVERNAME
                     + N'' - [FIX-2 FAILED] '' + QUOTENAME(@dbname)
                     + N''. Error: '' + ERROR_MESSAGE();
            EXEC xp_logevent @EVENT_ID, @msg, ''ERROR'';
        END CATCH;
        FETCH NEXT FROM chk_cur INTO @dbname;
    END;
    CLOSE chk_cur; DEALLOCATE chk_cur;

    /*-- Phase 4: LOG-ONLY findings ---------------------------------*/

    -- High VLF count
    DECLARE @vlf int, @avlf int, @logmb decimal(18,2);
    DECLARE log_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT database_name, vlf_count, active_vlf_count, log_size_mb
        FROM #LogInfo WHERE vlf_count >= @VLF_WARN;
    OPEN log_cur;
    FETCH NEXT FROM log_cur INTO @dbname, @vlf, @avlf, @logmb;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @severity = CASE WHEN @vlf >= @VLF_CRITICAL THEN ''ERROR'' ELSE ''WARNING'' END;
        SET @msg = N''['' + @TAG + N''] ['' + @severity + N''] '' + @@SERVERNAME
                 + N'' - [DBA REVIEW] High VLF count on '' + QUOTENAME(@dbname)
                 + N'': vlf_count='' + CAST(@vlf AS nvarchar(20))
                 + N'', active='' + CAST(@avlf AS nvarchar(20))
                 + N'', log_size_mb='' + CAST(@logmb AS nvarchar(20))
                 + N''. Action: schedule shrink+regrow in 8GB chunks.'';
        EXEC xp_logevent @EVENT_ID, @msg, @severity;
        FETCH NEXT FROM log_cur INTO @dbname, @vlf, @avlf, @logmb;
    END;
    CLOSE log_cur; DEALLOCATE log_cur;

    -- log_reuse_wait_desc problems (excluding OLDEST_PAGE)
    DECLARE @wait_desc nvarchar(60), @rec_model nvarchar(60), @action nvarchar(400);
    DECLARE wait_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT name, log_reuse_wait_desc, recovery_model_desc
        FROM sys.databases
        WHERE state_desc = ''ONLINE'' AND database_id <> 2
          AND log_reuse_wait_desc NOT IN (''NOTHING'',''OLDEST_PAGE'',''CHECKPOINT'',''LOG_SCAN'');
    OPEN wait_cur;
    FETCH NEXT FROM wait_cur INTO @dbname, @wait_desc, @rec_model;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @severity = CASE @wait_desc WHEN ''LOG_BACKUP'' THEN ''WARNING'' ELSE ''ERROR'' END;
        SET @action = CASE @wait_desc
            WHEN ''LOG_BACKUP''           THEN N''Verify log backup job. If PITR not required, consider SIMPLE recovery.''
            WHEN ''ACTIVE_TRANSACTION''   THEN N''Find long-running tran via DBCC OPENTRAN.''
            WHEN ''REPLICATION''          THEN N''Check log reader / CDC capture job health.''
            WHEN ''AVAILABILITY_REPLICA'' THEN N''Check AG secondary connectivity and redo lag.''
            WHEN ''DATABASE_MIRRORING''   THEN N''Check mirroring partner connectivity.''
            ELSE N''Investigate log_reuse_wait_desc.''
        END;
        SET @msg = N''['' + @TAG + N''] ['' + @severity + N''] '' + @@SERVERNAME
                 + N'' - [DBA REVIEW] Log truncation blocked on '' + QUOTENAME(@dbname)
                 + N'': log_reuse_wait_desc='' + @wait_desc
                 + N'', recovery='' + @rec_model
                 + N''. Action: '' + @action;
        EXEC xp_logevent @EVENT_ID, @msg, @severity;
        FETCH NEXT FROM wait_cur INTO @dbname, @wait_desc, @rec_model;
    END;
    CLOSE wait_cur; DEALLOCATE wait_cur;

    -- Log file high utilization
    DECLARE @pct decimal(5,2);
    DECLARE util_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT database_name, log_used_pct, log_size_mb
        FROM #LogInfo WHERE log_used_pct >= @LOG_USED_PCT_WARN;
    OPEN util_cur;
    FETCH NEXT FROM util_cur INTO @dbname, @pct, @logmb;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @msg = N''['' + @TAG + N''] [WARNING] '' + @@SERVERNAME
                 + N'' - [DBA REVIEW] Log high utilization on '' + QUOTENAME(@dbname)
                 + N'': used_pct='' + CAST(@pct AS nvarchar(20))
                 + N'', size_mb='' + CAST(@logmb AS nvarchar(20))
                 + N''. Action: investigate growth cause; verify log backups.'';
        EXEC xp_logevent @EVENT_ID, @msg, ''WARNING'';
        FETCH NEXT FROM util_cur INTO @dbname, @pct, @logmb;
    END;
    CLOSE util_cur; DEALLOCATE util_cur;

    -- FULL/BULK_LOGGED with no log backup in last 24h
    DECLARE @last_backup datetime;
    DECLARE backup_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name, d.recovery_model_desc, MAX(b.backup_finish_date)
        FROM   sys.databases d
        LEFT JOIN msdb.dbo.backupset b
               ON b.database_name = d.name AND b.type = ''L''
        WHERE  d.recovery_model_desc IN (''FULL'',''BULK_LOGGED'')
          AND  d.state_desc = ''ONLINE''
          AND  d.name NOT IN (''master'',''model'',''msdb'',''tempdb'')
        GROUP BY d.name, d.recovery_model_desc
        HAVING MAX(b.backup_finish_date) IS NULL
            OR MAX(b.backup_finish_date) < DATEADD(hour, -24, GETDATE());
    OPEN backup_cur;
    FETCH NEXT FROM backup_cur INTO @dbname, @rec_model, @last_backup;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @msg = N''['' + @TAG + N''] [ERROR] '' + @@SERVERNAME
                 + N'' - [DBA REVIEW] No recent log backup on '' + QUOTENAME(@dbname)
                 + N'': recovery='' + @rec_model
                 + N'', last_log_backup=''
                 + ISNULL(CONVERT(nvarchar(30), @last_backup, 120), N''NEVER'')
                 + N''. Action: configure log backups OR switch to SIMPLE recovery.'';
        EXEC xp_logevent @EVENT_ID, @msg, ''ERROR'';
        FETCH NEXT FROM backup_cur INTO @dbname, @rec_model, @last_backup;
    END;
    CLOSE backup_cur; DEALLOCATE backup_cur;

    /*-- Heartbeat --------------------------------------------------*/
    SET @msg = N''['' + @TAG + N''] [INFO] '' + @@SERVERNAME
             + N'' - VLF/log scan completed at ''
             + CONVERT(nvarchar(30), GETDATE(), 120) + N''.'';
    EXEC xp_logevent @EVENT_ID, @msg, ''INFORMATIONAL'';
END;
';

PRINT 'Procedure created.';

/*=======================================================================
  STEP 4 -- Ensure job category exists
=======================================================================*/
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.syscategories
               WHERE name = @CategoryNm AND category_class = 1)
BEGIN
    PRINT 'Creating job category: ' + @CategoryNm;
    EXEC msdb.dbo.sp_add_category
        @class = N'JOB',
        @type  = N'LOCAL',
        @name  = @CategoryNm;
END

/*=======================================================================
  STEP 5 -- Create the job
=======================================================================*/
PRINT 'Creating job: ' + @JobName;

DECLARE @jobId uniqueidentifier;

EXEC msdb.dbo.sp_add_job
    @job_name        = @JobName,
    @enabled         = 1,
    @description     = N'Scans every online database. Auto-fixes safe VLF/log conditions and writes findings to the Windows Application event log (event ID 60000, tag [VLFCHECK]) for DBA review. See VLF_HowTo.md.',
    @category_name   = @CategoryNm,
    @owner_login_name= @OwnerLogin,
    @notify_level_eventlog = 2,   -- on failure
    @job_id          = @jobId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
    @job_id          = @jobId,
    @step_name       = N'Run health check',
    @subsystem       = N'TSQL',
    @command         = N'EXEC msdb.dbo.usp_VLFHealthCheck;',
    @database_name   = N'msdb',
    @on_success_action = 1,   -- quit reporting success
    @on_fail_action  = 2;     -- quit reporting failure

EXEC msdb.dbo.sp_add_jobschedule
    @job_id              = @jobId,
    @name                = @ScheduleNm,
    @enabled             = 1,
    @freq_type           = 4,    -- daily
    @freq_interval       = 1,
    @freq_subday_type    = 4,    -- minutes
    @freq_subday_interval= 30,
    @active_start_time   = 0;

EXEC msdb.dbo.sp_add_jobserver
    @job_id     = @jobId,
    @server_name= N'(local)';

PRINT 'Job created and scheduled (every 30 minutes).';

/*=======================================================================
  STEP 6 -- Verification
=======================================================================*/
SELECT
    j.name              AS job_name,
    j.enabled           AS job_enabled,
    s.name              AS schedule_name,
    s.enabled           AS schedule_enabled,
    CASE s.freq_subday_type
        WHEN 4 THEN CAST(s.freq_subday_interval AS varchar(10)) + ' minutes'
        ELSE 'see msdb' END AS frequency,
    js.next_run_date,
    js.next_run_time
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobschedules js ON js.job_id      = j.job_id
JOIN msdb.dbo.sysschedules    s  ON s.schedule_id  = js.schedule_id
WHERE j.name = @JobName;

PRINT '=== VLF Health Check deployment complete on ' + @@SERVERNAME + ' ===';
GO
