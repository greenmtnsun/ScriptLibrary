/*===========================================================================
  04_VLF_Drop_Job.sql
  -------------------------------------------------------------------------
  Idempotent removal of the VLF Health Check.

  Drops:
    - SQL Agent job     : DBA - VLF Health Check  (and its schedule)
    - Stored procedure  : msdb.dbo.usp_VLFHealthCheck

  Safe to run repeatedly. Does nothing (cleanly) if the objects do not exist.
  Does NOT purge job history from msdb.dbo.sysjobhistory or event log entries
  already written - those are preserved as audit trail.

  Run as : sysadmin
===========================================================================*/

SET NOCOUNT ON;

DECLARE @JobName  sysname = N'DBA - VLF Health Check';

PRINT '=== VLF Health Check removal starting on ' + @@SERVERNAME + ' ===';

/*=======================================================================
  STEP 1 -- Stop the job if it is currently running
=======================================================================*/
IF EXISTS (
    SELECT 1
    FROM msdb.dbo.sysjobs           j
    JOIN msdb.dbo.sysjobactivity    a ON a.job_id = j.job_id
    JOIN msdb.dbo.syssessions       s ON s.session_id = a.session_id
    WHERE j.name = @JobName
      AND a.start_execution_date IS NOT NULL
      AND a.stop_execution_date IS NULL
      AND s.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
)
BEGIN
    PRINT 'Job is currently running - issuing stop.';
    BEGIN TRY
        EXEC msdb.dbo.sp_stop_job @job_name = @JobName;
    END TRY
    BEGIN CATCH
        PRINT 'Stop request returned: ' + ERROR_MESSAGE();
    END CATCH;
END

/*=======================================================================
  STEP 2 -- Drop the job (and its unused schedule)
=======================================================================*/
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName)
BEGIN
    PRINT 'Dropping job: ' + @JobName;
    EXEC msdb.dbo.sp_delete_job
        @job_name              = @JobName,
        @delete_unused_schedule = 1;
END
ELSE
    PRINT 'No job to drop.';

/*=======================================================================
  STEP 3 -- Drop the stored procedure
=======================================================================*/
IF OBJECT_ID('msdb.dbo.usp_VLFHealthCheck') IS NOT NULL
BEGIN
    PRINT 'Dropping procedure: msdb.dbo.usp_VLFHealthCheck';
    EXEC msdb.dbo.sp_executesql N'DROP PROCEDURE dbo.usp_VLFHealthCheck;';
END
ELSE
    PRINT 'No procedure to drop.';

/*=======================================================================
  STEP 4 -- Verification
=======================================================================*/
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName)
   OR OBJECT_ID('msdb.dbo.usp_VLFHealthCheck') IS NOT NULL
BEGIN
    RAISERROR('Removal incomplete - one or more objects remain.', 16, 1);
END
ELSE
    PRINT 'All VLF Health Check objects removed.';

PRINT '=== VLF Health Check removal complete on ' + @@SERVERNAME + ' ===';
GO
