#Requires -Version 5.1
#Requires -Modules dbatools

<#
.SYNOPSIS
    SQL Server Agent job telemetry and runaway-job anomaly detection.

.DESCRIPTION
    Identifies actively executing SQL Agent jobs on the target instance,
    detects blocking-chain "stuck" conditions via DMV interrogation, and
    statistically evaluates current execution durations against historical
    baselines using the Median Absolute Deviation (MAD) and Modified
    Z-score (Iglewicz / Hoaglin, 1993).

    Two detection paths:
      - Stuck (locked): job is blocked behind another session, no
        statistical analysis needed - emit Event ID 1001.
      - Runaway: job is actively running but its current duration's
        Modified Z-score exceeds the configured threshold - emit
        Event ID 2001.

    Anomaly records are written to the Windows Event Log under the
    configured source for downstream SIEM ingestion. The function
    also returns a result object the caller can inspect.

.PARAMETER SqlInstance
    Target SQL Server instance. Defaults to the local default instance.

.PARAMETER MinRunDurationSeconds
    Skip statistical evaluation for jobs whose current duration is
    below this threshold. Prevents alert fatigue on micro-duration
    variances (and prevents divide-by-zero when historical MAD is
    near 0 for high-frequency micro-jobs). Default 300s.

.PARAMETER MinSampleCount
    Skip statistical evaluation when historical successful-run count
    is below this threshold. Prevents acting on baselines built from
    too few samples. Default 5.

.PARAMETER MadAnomalyThreshold
    Modified Z-score absolute value above which a runaway is declared.
    Iglewicz / Hoaglin's recommended threshold is 3.5. Default 3.5.

.PARAMETER EventLogName
    Windows event log name. Default "Application".

.PARAMETER EventSource
    Event source under which records are written. Created on first run
    (requires elevation; the script throws cleanly if not elevated and
    the source doesn't already exist). Default "SQLAgentTelemetry".

.NOTES
    Execution context:
      - SQL login mapped to a Windows principal with VIEW SERVER STATE
        plus SQLAgentReaderRole on msdb.
      - Schedule via SQL Agent CmdExec, NEVER the native PowerShell
        subsystem (SQLPS hangs on dbatools loads).
      - First run requires local Administrator (to register the event
        source). Subsequent runs do not.

    Algorithm:
      Median  = median(historical successful durations)
      MAD     = median(|x_i - median|)
      M_i     = 0.6745 * (current - median) / MAD
      Anomaly when |M_i| > MadAnomalyThreshold (default 3.5).

.EXAMPLE
    .\Invoke-TelemetryANDAnomoly.ps1 -SqlInstance 'sql01\PROD'

.EXAMPLE
    .\Invoke-TelemetryANDAnomoly.ps1 -MinRunDurationSeconds 60 -MadAnomalyThreshold 4.0 -Verbose
#>

[CmdletBinding()]
param(
    [string]$SqlInstance         = 'localhost',

    [ValidateRange(1, 86400)]
    [int]$MinRunDurationSeconds  = 300,

    [ValidateRange(1, 1000)]
    [int]$MinSampleCount         = 5,

    [ValidateRange(1.0, 10.0)]
    [double]$MadAnomalyThreshold = 3.5,

    [string]$EventLogName        = 'Application',

    [string]$EventSource         = 'SQLAgentTelemetry'
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1. Initialization
# ---------------------------------------------------------------------------
# Event log source registration is admin-only. If the source already
# exists, no admin token needed; if it doesn't, we have to register it,
# and a non-elevated process will hit a SecurityException. Fail clean.
try {
    Import-Module dbatools -ErrorAction Stop

    if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
        $principal = [System.Security.Principal.WindowsPrincipal]::new(
                         [System.Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw "Event source '$EventSource' is not registered, and the current process is not elevated. Run once as Administrator to register it, then unprivileged runs will work."
        }
        [System.Diagnostics.EventLog]::CreateEventSource($EventSource, $EventLogName)
    }
} catch {
    Write-Error "Initialization failed: $($_.Exception.Message)"
    exit 1
}

# Result accumulator returned to caller. EventLog is the durable record;
# this object lets callers chain / pipeline / test without parsing logs.
$results = New-Object System.Collections.Generic.List[object]

function Add-TelemetryRecord {
    param(
        [Parameter(Mandatory)] [string]$State,
        [Parameter(Mandatory)] [int]$EventId,
        [Parameter(Mandatory)] [ValidateSet('Information','Warning','Error')] [string]$EntryType,
        [Parameter(Mandatory)] [hashtable]$Payload
    )
    $json = $Payload | ConvertTo-Json -Compress -Depth 5
    try {
        Write-EventLog -LogName $EventLogName -Source $EventSource `
            -EventId $EventId -EntryType $EntryType -Message $json
    } catch {
        Write-Warning "Event log write failed (EventId=$EventId): $($_.Exception.Message)"
    }
    $results.Add([pscustomobject]@{
        Timestamp = (Get-Date).ToUniversalTime().ToString('o')
        State     = $State
        EventId   = $EventId
        EntryType = $EntryType
        Payload   = $Payload
    })
}

# ---------------------------------------------------------------------------
# 2. Blocking chain analysis - stuck / locked jobs
# ---------------------------------------------------------------------------
$blockingQuery = @'
SELECT
    es.session_id,
    es.program_name,
    wt.blocking_session_id,
    wt.wait_type,
    wt.wait_duration_ms
FROM sys.dm_exec_sessions es
INNER JOIN sys.dm_os_waiting_tasks wt ON es.session_id = wt.session_id
WHERE es.program_name LIKE 'SQLAgent - TSQL JobStep%'
  AND wt.blocking_session_id IS NOT NULL
  AND wt.blocking_session_id > 0;
'@

try {
    $blocked = Invoke-DbaQuery -SqlInstance $SqlInstance -Query $blockingQuery -ErrorAction Stop
    foreach ($s in $blocked) {
        Add-TelemetryRecord -State 'STUCK_LOCKED' -EventId 1001 -EntryType Warning -Payload @{
            State        = 'STUCK_LOCKED'
            SessionId    = $s.session_id
            BlockedBy    = $s.blocking_session_id
            WaitType     = $s.wait_type
            WaitDurationMs = $s.wait_duration_ms
            Program      = $s.program_name
        }
    }
} catch {
    Add-TelemetryRecord -State 'BLOCKING_QUERY_FAILED' -EventId 5000 -EntryType Error -Payload @{
        Error = $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# 3. Active job isolation
# ---------------------------------------------------------------------------
# Promote dbatools errors to terminating so they're visible. Silently
# swallowing makes "no active jobs" indistinguishable from "dbatools blew up."
try {
    $activeJobs = @(Get-DbaRunningJob -SqlInstance $SqlInstance -ErrorAction Stop)
} catch {
    Add-TelemetryRecord -State 'ACTIVE_JOB_QUERY_FAILED' -EventId 5001 -EntryType Error -Payload @{
        Error = $_.Exception.Message
    }
    return $results.ToArray()
}

if ($activeJobs.Count -eq 0) {
    Write-Verbose 'No active SQL Agent jobs; exiting cleanly.'
    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# 4. Statistical evaluation - MAD-based runaway detection
# ---------------------------------------------------------------------------
foreach ($job in $activeJobs) {

    # StartDate is the active execution's start time on the running job.
    if (-not $job.StartDate) {
        Write-Verbose "Job '$($job.Name)' has no StartDate; skipping."
        continue
    }

    $currentDurationSeconds = ((Get-Date) - $job.StartDate).TotalSeconds

    # Gate: ignore micro-jobs (alert fatigue + divide-by-zero risk on
    # zero-variance high-frequency workloads).
    if ($currentDurationSeconds -lt $MinRunDurationSeconds) {
        Write-Verbose "Job '$($job.Name)' currentDuration=${currentDurationSeconds}s below floor; skipping."
        continue
    }

    # Historical baseline. Use @(...) to force array semantics so .Count
    # is safe when the foreach yields nothing.
    $history = @(
        Get-DbaAgentJobHistory -SqlInstance $SqlInstance -Job $job.Name -ErrorAction SilentlyContinue |
            Where-Object { $_.RunStatus -eq 'Succeeded' }
    )

    if ($history.Count -lt $MinSampleCount) {
        Write-Verbose "Job '$($job.Name)' has $($history.Count) successful runs (< $MinSampleCount); baseline-acquisition phase."
        continue
    }

    $historicalDurations = @(
        foreach ($run in $history) {
            if ($run.EndDate -and $run.StartDate) {
                ($run.EndDate - $run.StartDate).TotalSeconds
            }
        }
    ) | Where-Object { $_ -is [double] -or $_ -is [int] } | Sort-Object

    $historicalDurations = @($historicalDurations)
    if ($historicalDurations.Count -lt $MinSampleCount) {
        Write-Verbose "Job '$($job.Name)' has $($historicalDurations.Count) usable durations after filtering; skipping."
        continue
    }

    # Median of historical durations
    $hCount   = $historicalDurations.Count
    $midH     = [math]::Floor($hCount / 2)
    $medianDuration = if (($hCount % 2) -ne 0) {
        $historicalDurations[$midH]
    } else {
        ($historicalDurations[$midH - 1] + $historicalDurations[$midH]) / 2
    }

    # Absolute deviations from median, sorted
    $absoluteDeviations = @(
        $historicalDurations | ForEach-Object { [math]::Abs($_ - $medianDuration) }
    ) | Sort-Object
    $absoluteDeviations = @($absoluteDeviations)

    # Median Absolute Deviation. Use the deviation array's own count;
    # do NOT reuse the historical-durations index (they happen to have
    # the same count today but the assumption is fragile).
    $aCount = $absoluteDeviations.Count
    $midA   = [math]::Floor($aCount / 2)
    $MAD    = if (($aCount % 2) -ne 0) {
        $absoluteDeviations[$midA]
    } else {
        ($absoluteDeviations[$midA - 1] + $absoluteDeviations[$midA]) / 2
    }

    # Floor MAD to a microscopic positive value to prevent divide-by-zero
    # on zero-variance histories (every previous run had identical duration).
    if ($MAD -le 0) { $MAD = 0.001 }

    # Modified Z-score: 0.6745 keeps the result on the same scale as a
    # standard Z-score under a normal distribution.
    $modifiedZScore = (0.6745 * ($currentDurationSeconds - $medianDuration)) / $MAD

    if ([math]::Abs($modifiedZScore) -gt $MadAnomalyThreshold) {
        Add-TelemetryRecord -State 'RUNAWAY_ANOMALY' -EventId 2001 -EntryType Warning -Payload @{
            State                   = 'RUNAWAY_ANOMALY'
            JobName                 = $job.Name
            CurrentDurationSeconds  = [math]::Round($currentDurationSeconds, 2)
            HistoricalMedianSeconds = [math]::Round($medianDuration, 2)
            CalculatedMAD           = [math]::Round($MAD, 4)
            ModifiedZScore          = [math]::Round($modifiedZScore, 2)
            Threshold               = $MadAnomalyThreshold
            HistoricalSamples       = $historicalDurations.Count
        }
    } else {
        Write-Verbose "Job '$($job.Name)' Z=$([math]::Round($modifiedZScore,2)) within tolerance."
    }
}

# Return the structured record set so callers can pipeline or test.
$results.ToArray()
