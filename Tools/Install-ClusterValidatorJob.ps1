#Requires -Version 5.1

<#
.SYNOPSIS
    Idempotently install the ClusterValidator SQL Agent job.

.DESCRIPTION
    Creates (or replaces) a SQL Agent job that runs the ClusterValidator
    via the CmdExec subsystem. The CmdExec subsystem is mandatory:
    the native SQL Agent PowerShell subsystem invokes legacy SQLPS.exe,
    which is documented to hang and to silently break complex modules.

    The generated job:
      - runs as a SQL Agent proxy mapped to a Windows credential
        (typically a gMSA)
      - executes the back-compat wrapper Invoke-clusterValidator.ps1,
        which forwards to Invoke-ClusterValidator via the module
      - passes -ConfigPath, optionally -CredentialSecretName,
        -HardenReportAcl, and -WriteEventLog
      - is owned by sa
      - schedules weekly at the supplied day/time
      - notifies an operator on failure (when -OperatorName is given)

    The script is idempotent: re-running drops and re-creates the job
    cleanly. Use -DryRun to preview the T-SQL without executing.

.PARAMETER SqlInstance
    Target SQL Server instance hosting the SQL Agent that will own the
    job. Defaults to the local default instance.

.PARAMETER JobName
    Job name in msdb.dbo.sysjobs. Defaults to 'ClusterValidator'.

.PARAMETER WrapperPath
    Absolute path to Invoke-clusterValidator.ps1 on the SQL host.

.PARAMETER ConfigPath
    Absolute path to the per-cluster JSON config file.

.PARAMETER CredentialSecretName
    SecretManagement secret name to forward as -CredentialSecretName.
    Optional; omit if the gMSA principal has direct remoting rights.

.PARAMETER ProxyName
    Existing SQL Agent CmdExec proxy mapped to the gMSA. Required.

.PARAMETER OperatorName
    Existing SQL Agent operator to notify on job failure. Optional.

.PARAMETER ScheduleDay
    Day of week for the weekly schedule. Defaults to Sunday.

.PARAMETER ScheduleTime
    Local time for the weekly schedule, format HH:mm. Defaults to 03:00.

.PARAMETER WriteEventLog
    Pass -WriteEventLog through to the validator (recommended).

.PARAMETER HardenReportAcl
    Pass -HardenReportAcl through to the validator (recommended for prod).

.PARAMETER DryRun
    Print the T-SQL that would be executed and exit without modifying
    anything.

.EXAMPLE
    .\Tools\Install-ClusterValidatorJob.ps1 `
        -SqlInstance      'sql01\PROD'        `
        -WrapperPath      'D:\ScriptLibrary\Invoke-clusterValidator.ps1' `
        -ConfigPath       'D:\ScriptLibrary\Config\prod.json'            `
        -CredentialSecretName 'ClusterValidator' `
        -ProxyName        'ClusterValidatorProxy' `
        -OperatorName     'DBATeam' `
        -HardenReportAcl  `
        -WriteEventLog
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SqlInstance = '.',

    [string]$JobName = 'ClusterValidator',

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$WrapperPath,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$ConfigPath,

    [string]$CredentialSecretName,

    [Parameter(Mandatory = $true)]
    [string]$ProxyName,

    [string]$OperatorName,

    [ValidateSet('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')]
    [string]$ScheduleDay = 'Sunday',

    [ValidatePattern('^\d{2}:\d{2}$')]
    [string]$ScheduleTime = '03:00',

    [switch]$WriteEventLog,

    [switch]$HardenReportAcl,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Build the CmdExec command line. Defensive parameters (-NoProfile,
# -NonInteractive, -ExecutionPolicy Bypass) match the .NOTES of the
# wrapper script. The -File form (not -Command) ensures proper arg
# parsing under cmd.exe.
$validatorArgs = @(
    "-ConfigPath", "`"$ConfigPath`""
)
if ($CredentialSecretName) { $validatorArgs += @('-CredentialSecretName', "`"$CredentialSecretName`"") }
if ($HardenReportAcl)      { $validatorArgs += '-HardenReportAcl' }
if ($WriteEventLog)        { $validatorArgs += '-WriteEventLog' }

$cmdExecCommand = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" {1}' -f
    $WrapperPath, ($validatorArgs -join ' ')

# Map ScheduleDay → freq_interval bitmask used by sp_add_jobschedule
# (Sun=1, Mon=2, Tue=4, Wed=8, Thu=16, Fri=32, Sat=64).
$dayBit = @{
    Sunday    = 1
    Monday    = 2
    Tuesday   = 4
    Wednesday = 8
    Thursday  = 16
    Friday    = 32
    Saturday  = 64
}[$ScheduleDay]

# HHmmss integer that sp_add_jobschedule expects for active_start_time
$hhmm = $ScheduleTime -replace ':',''
$startTime = [int]("${hhmm}00")

# Build T-SQL. Job name and other identifiers are interpolated into the
# script; nothing here takes user data, so QUOTENAME-style escaping
# isn't required, but we still use single-quote-doubling for safety.
function Escape-Sql {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    $Value -replace "'", "''"
}

$jobNameSql       = Escape-Sql $JobName
$cmdExecSql       = Escape-Sql $cmdExecCommand
$proxyNameSql     = Escape-Sql $ProxyName
$operatorNameSql  = if ($OperatorName) { Escape-Sql $OperatorName } else { '' }

$tsql = @"
SET NOCOUNT ON;
USE [msdb];

DECLARE @jobName     sysname = N'$jobNameSql';
DECLARE @category    sysname = N'[Uncategorized (Local)]';
DECLARE @proxyName   sysname = N'$proxyNameSql';

-- Idempotent: drop existing job with the same name.
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = @jobName)
BEGIN
    EXEC dbo.sp_delete_job @job_name = @jobName, @delete_history = 1, @delete_unused_schedule = 1;
END

EXEC dbo.sp_add_job
    @job_name        = @jobName,
    @enabled         = 1,
    @description     = N'ClusterValidator weekly run. Triages failover-cluster health (storage, MPIO, SCSI-3, quorum, heartbeat, time, hotfix parity, service accounts) and runs Test-Cluster. Forensic cluster log captured automatically on Fail.',
    @category_name   = @category,
    @owner_login_name = N'sa';

EXEC dbo.sp_add_jobstep
    @job_name      = @jobName,
    @step_name     = N'Run ClusterValidator',
    @subsystem     = N'CmdExec',
    @command       = N'$cmdExecSql',
    @on_success_action = 1,   -- Quit with success
    @on_fail_action    = 2,   -- Quit with failure
    @retry_attempts    = 0,
    @flags             = 0,
    @proxy_name        = @proxyName;

EXEC dbo.sp_add_schedule
    @schedule_name      = N'$jobNameSql Weekly',
    @enabled            = 1,
    @freq_type          = 8,                  -- weekly
    @freq_interval      = $dayBit,
    @freq_recurrence_factor = 1,
    @active_start_time  = $startTime;

EXEC dbo.sp_attach_schedule
    @job_name      = @jobName,
    @schedule_name = N'$jobNameSql Weekly';

EXEC dbo.sp_add_jobserver
    @job_name      = @jobName,
    @server_name   = N'(local)';
"@

if ($OperatorName) {
    $tsql += @"

-- Failure notification
EXEC dbo.sp_update_job
    @job_name              = N'$jobNameSql',
    @notify_level_email    = 2,    -- on failure
    @notify_email_operator_name = N'$operatorNameSql';
"@
}

# Render or execute.
if ($DryRun) {
    Write-Host '--- DRY RUN: T-SQL would execute the following ---' -ForegroundColor Cyan
    Write-Host $tsql
    return
}

if (-not $PSCmdlet.ShouldProcess($SqlInstance, "Install/replace SQL Agent job '$JobName'")) {
    return
}

# Use sqlcmd via the .NET SqlClient if available (no module dependency).
Add-Type -AssemblyName 'System.Data'
$conn = [System.Data.SqlClient.SqlConnection]::new("Server=$SqlInstance;Database=msdb;Integrated Security=True;Application Name=Install-ClusterValidatorJob")
try {
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText    = $tsql
    $cmd.CommandTimeout = 60
    [void]$cmd.ExecuteNonQuery()
    Write-Host "Installed SQL Agent job '$JobName' on $SqlInstance." -ForegroundColor Green
}
finally {
    if ($conn) { $conn.Dispose() }
}
