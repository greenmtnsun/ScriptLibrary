⚙️ AgentWatchdog.ps1 - Project Wiki

Welcome to the AgentWatchdog documentation. This project provides a localized, statistical approach to monitoring SQL Server Agent jobs, ensuring runaway or stuck jobs are caught before they impact downstream processes.

Table of Contents

Architecture & Topology

Statistical Anomaly Engine

Edge Cases & Mitigations

Development Action Plan

1. Architecture & Topology

Managing thousands of SQL Server Agent jobs across multiple environments often leads to silent failures. Traditional monitoring relies on hardcoded time limits (e.g., "Alert if Job X runs longer than 60 minutes"). This tool replaces static thresholds with a dynamic, self-adjusting statistical model.

Distributed, Local Execution

A key design principle of AgentWatchdog is local execution.

No linked servers or massive cross-server queries. The PowerShell module is deployed locally to each SQL Server instance.

The script queries the local msdb database directly to evaluate currently running jobs against their own historical baselines.

Centralized Alerting: If a local watchdog script detects an anomaly, it pushes an alert outward (via Webhook, REST API, or writing to a central logging table).

Topology Flow:

[ Server A (msdb) ] ---> (Runs Local Watchdog.ps1) ---\
                                                       \
[ Server B (msdb) ] ---> (Runs Local Watchdog.ps1) -------> [ Central Alerting Hub ]
                                                       /    (Teams, Slack, Email, etc.)
[ Server C (msdb) ] ---> (Runs Local Watchdog.ps1) ---/


2. Statistical Anomaly Engine

Instead of static rules, the script analyzes msdb.dbo.sysjobhistory. It calculates the rolling Mean and Standard Deviation for each specific job. If a currently running job exceeds the mean by +2 or +3 Standard Deviations, it is flagged as a "runaway."

Why Statistics?

Self-Adjusting: As databases grow and normal jobs take naturally longer, the baseline adapts automatically.

Zero Configuration: No need for DBAs to manually input or update thresholds for thousands of distinct jobs.

Reduces Alert Fatigue: Eliminates false positives caused by arbitrary static limits on normally long-running jobs.

Core PowerShell Logic Example

# Extract run durations (in seconds) for a specific job from msdb
$JobHistory = Get-SqlJobHistory -JobName $JobName
$Durations = $JobHistory.RunDurationInSeconds

# Calculate Mean (Average)
$Mean = ($Durations | Measure-Object -Average).Average

# Calculate Variance and Standard Deviation
$Variance = ($Durations | ForEach-Object { 
    [math]::Pow($_ - $Mean, 2) 
} | Measure-Object -Average).Average

$StdDev = [math]::Sqrt($Variance)

# Define the acceptable threshold (Mean + 2 Standard Deviations)
$Threshold = $Mean + (2 * $StdDev)

# Evaluate currently running job
if ($CurrentRunTime -gt $Threshold) { 
    Write-Warning "Runaway Job Detected! Job $JobName is running beyond expected statistical limits."
    # Trigger alert webhook here
}


3. Edge Cases & Mitigations

Statistics fail when data is sparse, highly volatile, or undergoing structural shifts. The script must be hardened to handle these scenarios where past performance cannot be blindly trusted.

1. The "First Run" Problem

Problem: A brand new job is deployed. There is no historical data in msdb to calculate a mean or standard deviation.

Solution: Implement a global fallback threshold parameter (e.g., -DefaultMaxMinutes 120). If historical execution count is < 5, bypass statistical checks and use the hardcoded fallback until a baseline is established.

2. Bimodal Distributions

Problem: A job runs daily taking 5 minutes, but on the last day of the month, it intentionally takes 4 hours. Daily stats will falsely flag the monthly run.

Solution: Contextual bucketing. Group the history statistics by the schedule_id to create separate baselines for daily vs. monthly executions.

3. The Structural Shift

Problem: An index was added, dropping a job's run time from 60m to 5m. Past stats (60m) are now irrelevant and won't catch a 40m stuck job.

Solution: Time-Windowing / Exponential Moving Average. Do not use all-time history. Only calculate statistics against the last 14 or 30 days of runs. This allows the baseline to "forget" old performance paradigms.

4. Infrequent Long-Runners

Problem: A quarterly archiving job takes 12 hours. Because it runs infrequently, a localized temporary spike might throw standard deviations wildly off.

Solution: Cap the Standard Deviation multiplier. Provide a JSON configuration file locally allowing DBAs to manually override specific job_ids to ignore statistical checks.

4. Development Action Plan

To get this built quickly, we recommend a focused 4-hour sprint involving a DBA and a PowerShell developer.

Sprint Breakdown (4 Hours)

Hour 1: Core Research & T-SQL Prep

Research msdb tables (sysjobs, sysjobhistory, sysjobactivity).

Write base T-SQL queries to extract cleanly formatted historical durations, filtering out cancelled/failed runs for an accurate baseline.

Hour 2: PowerShell Statistical Logic

Develop the PS library functions (Measure-JobHistory).

Implement the time-window logic (e.g., last 30 days only) to mitigate structural shifts.

Hour 3: The Watchdog Loop & Edge Cases

Write the main execution block to query currently running jobs.

Cross-reference current run times with baselines.

Implement the "First Run" fallback threshold logic.

Hour 4: Hardening & Testing

Add Try/Catch blocks, error logging, and central webhook integration.

Deploy to a single DEV server. Intentionally stall a test job using WAITFOR DELAY to trigger the watchdog.

Expected Deliverables

SqlWatchdogCore.psm1 (The core library housing statistical math and T-SQL execution).

Invoke-JobMonitor.ps1 (The main scheduled script).

config_template.json (Local configuration for overrides and webhooks).
