<#
.SYNOPSIS
    Advanced SQL Server Agent Job Telemetry and Anomaly Detection.
.DESCRIPTION
    This script identifies actively executing SQL Agent jobs, detects blocking chains,
    calculates historical Median Absolute Deviation (MAD), and evaluates current
    execution durations against calculated Modified Z-Scores to detect runaway states.
.NOTES
    Execution Context: Requires SQLAgentReaderRole and VIEW SERVER STATE.
    Subsystem: Must be run via CmdExec, NOT the native SQLPS subsystem.
#>


param (
    [string]$SqlInstance = "localhost",
    [int]$MinRunDurationSeconds = 300,  # Bypasses micro-jobs to avoid zero-variance division
    [int]$MinSampleCount = 5,           # Bypasses new jobs lacking historical data
    [double]$MadAnomalyThreshold = 3.5, # The mathematical boundary for a Modified Z-score anomaly
    [string]$EventLogName = "Application",
    [string]$EventSource = "SQLAgentTelemetry"
)

# 1. Initialization and Dependency Validation
try {
    if (-not (Get-Module -Name dbatools -ListAvailable)) {
        throw "Critical Dependency Missing: dbatools module is not installed."
    }
    Import-Module dbatools -ErrorAction Stop

    # Ensure the Event Log Source exists for structured logging
    if (-not::SourceExists($EventSource)) {
       ::CreateEventSource($EventSource, $EventLogName)
    }
}
catch {
    Write-Error "Initialization failed: $_"
    exit
}

# 2. Blocking Chain Analysis (Detecting Stuck Jobs)
# Interrogates DMVs to identify if any active SQL Agent SPID is physically blocked.
$blockingQuery = @"
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
"@

try {
    $blockedSessions = Invoke-DbaQuery -SqlInstance $SqlInstance -Query $blockingQuery -ErrorAction Stop
    
    foreach ($session in $blockedSessions) {
        # If a blocking session is found, the job is stuck. Statistical analysis is bypassed.
        $logMessage = @{
            State = "STUCK_LOCKED"
            SessionId = $session.session_id
            BlockedBy = $session.blocking_session_id
            WaitType = $session.wait_type
            Program = $session.program_name
        } | ConvertTo-Json -Compress

        Write-EventLog -LogName $EventLogName -Source $EventSource -EventId 1001 -EntryType Warning -Message $logMessage
    }
}
catch {
    Write-EventLog -LogName $EventLogName -Source $EventSource -EventId 5000 -EntryType Error -Message "Blocking analysis failed: $_"
}

# 3. Active Job Isolation
# Retrieves only the jobs currently executing, filtering out all idle configurations.
$activeJobs = Get-DbaRunningJob -SqlInstance $SqlInstance -ErrorAction SilentlyContinue

if (-not $activeJobs) {
    # No active jobs executing. Exit cleanly to maintain idempotency.
    exit
}

# 4. Statistical Evaluation (Median Absolute Deviation and Modified Z-Score)
foreach ($job in $activeJobs) {
    
    # Calculate how long the job has currently been running
    $currentDuration = (Get-Date) - $job.LastRunDate
    $currentDurationSeconds = $currentDuration.TotalSeconds

    # GATING LOGIC: Ignore micro-jobs to prevent divide-by-zero on zero-variance workloads
    if ($currentDurationSeconds -lt $MinRunDurationSeconds) {
        continue 
    }

    # Retrieve historical execution data to build the baseline
    $history = Get-DbaAgentJobHistory -SqlInstance $SqlInstance -Job $job.Name -ErrorAction SilentlyContinue | 
               Where-Object { $_.RunStatus -eq 'Succeeded' }

    # GATING LOGIC: Ignore newly created jobs with insufficient historical samples
    if ($history.Count -lt $MinSampleCount) {
        continue
    }

    # Data Type Transformation: Calculate explicit seconds for historical runs
    $historicalDurations = foreach ($run in $history) {
        if ($run.EndDate -and $run.StartDate) {
            ($run.EndDate - $run.StartDate).TotalSeconds
        }
    }

    $historicalDurations = $historicalDurations | Where-Object { $_ -ne $null } | Sort-Object

    if ($historicalDurations.Count -lt $MinSampleCount) { continue }

    # Mathematics: Step 1 - Calculate the Median of historical durations
    $midIndex = [math]::Floor($historicalDurations.Count / 2)
    if (($historicalDurations.Count % 2) -ne 0) {
        $medianDuration = $historicalDurations[$midIndex]
    } else {
        $medianDuration = ($historicalDurations[$midIndex - 1] + $historicalDurations[$midIndex]) / 2
    }

    # Mathematics: Step 2 - Calculate the Absolute Deviations from the Median
    $absoluteDeviations = foreach ($duration in $historicalDurations) {
        [math]::Abs($duration - $medianDuration)
    }
    $absoluteDeviations = $absoluteDeviations | Sort-Object

    # Mathematics: Step 3 - Calculate the Median Absolute Deviation (MAD)
    if (($absoluteDeviations.Count % 2) -ne 0) {
        $MAD = $absoluteDeviations[$midIndex]
    } else {
        $MAD = ($absoluteDeviations[$midIndex - 1] + $absoluteDeviations[$midIndex]) / 2
    }

    # GATING LOGIC: Prevent Divide-By-Zero. If MAD is 0, assign a microscopic float value.
    if ($MAD -eq 0) { $MAD = 0.001 }

    # Mathematics: Step 4 - Calculate the Modified Z-Score for the CURRENT execution
    $modifiedZScore = (0.6745 * ($currentDurationSeconds - $medianDuration)) / $MAD

    # 5. Anomaly Detection and Alerting
    if ($modifiedZScore -gt $MadAnomalyThreshold) {
        
        # Construct the structured telemetry payload
        $anomalyPayload = @{
            State = "RUNAWAY_ANOMALY"
            JobName = $job.Name
            CurrentDurationSeconds = [math]::Round($currentDurationSeconds, 2)
            HistoricalMedianSeconds = [math]::Round($medianDuration, 2)
            CalculatedMAD = [math]::Round($MAD, 2)
            ModifiedZScore = [math]::Round($modifiedZScore, 2)
            Threshold = $MadAnomalyThreshold
        } | ConvertTo-Json -Compress

        # Write to Event Log for SIEM ingestion and operational alerting
        Write-EventLog -LogName $EventLogName -Source $EventSource -EventId 2001 -EntryType Warning -Message $anomalyPayload
    }
}
