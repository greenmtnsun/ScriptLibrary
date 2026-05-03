<#
.SYNOPSIS
    Targeted Validation for a 4-node / 5-instance SQL Failover Cluster.

.DESCRIPTION
    Performs pre-flight, storage delivery, MPIO, and SCSI-3 Persistent Reservation
    checks across the supplied node list, then invokes the official Microsoft
    Test-Cluster validation suite. Results are written to a timestamped HTML report
    and a structured JSON summary, with optional Windows Event Log emission for
    SIEM ingestion.

    The script is engineered to be non-destructive: it never issues
    PR_REGISTER_AND_IGNORE or PR_RESERVE writes against shared LUNs. SCSI-3
    reservations are interrogated via Get-ClusterSharedVolume / Get-Disk and the
    cluster's own reservation state, rather than by issuing raw SCSI commands.

.PARAMETER Nodes
    The four cluster node short names. Order is not significant.

.PARAMETER ExpectedDiskCount
    The number of shared cluster disks each node should see (excludes the OS
    disk). Defaults to 32 for the legacy SAN topology this script was built for.

.PARAMETER ReportPath
    Output directory for the HTML and JSON artifacts. Defaults to C:\Temp.

.PARAMETER IncludeTests
    Test-Cluster category filter. Defaults to the four categories appropriate
    for a traditional SAN/VMware FCI (Inventory, Network, System Configuration,
    Storage).

.PARAMETER WriteEventLog
    When set, writes a structured JSON summary to the Application event log
    under the ClusterValidator source.

.NOTES
    Execution Context:
      - Run from a node that is a member of the cluster, or from a management
        host with the FailoverClusters and MPIO modules installed and Kerberos
        delegation to all four nodes.
      - The executing principal requires local Administrators on each node
        and the Cluster 'Full Control' permission.
      - Do NOT run inside SQLPS.exe; invoke from standard powershell.exe with
        -NoProfile -NonInteractive -ExecutionPolicy Bypass.
#>

param (
    [Parameter(Mandatory = $true)]
    [ValidateCount(2, 16)]
    [string[]]$Nodes,

    [ValidateRange(1, 1024)]
    [int]$ExpectedDiskCount = 32,

    [ValidateScript({ Test-Path -Path $_ -PathType Container })]
    [string]$ReportPath = 'C:\Temp',

    [string[]]$IncludeTests = @('Inventory', 'Network', 'System Configuration', 'Storage'),

    [string[]]$ExcludeTests = @('Storage Spaces Direct'),

    [switch]$WriteEventLog,

    [string]$EventLogName = 'Application',

    [string]$EventSource  = 'ClusterValidator'
)

$ErrorActionPreference = 'Stop'
$timestamp   = Get-Date -Format 'yyyyMMdd_HHmm'
$htmlReport  = Join-Path $ReportPath "ClusterValidation_${timestamp}.html"
$jsonReport  = Join-Path $ReportPath "ClusterValidation_${timestamp}.json"

# Structured result accumulator. Each phase appends a record so the final
# JSON artifact is consumable by SIEM / dashboard pipelines without parsing
# free-form host output.
$results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param(
        [Parameter(Mandatory)] [string]$Phase,
        [Parameter(Mandatory)] [ValidateSet('Pass', 'Warn', 'Fail', 'Info')] [string]$Status,
        [Parameter(Mandatory)] [string]$Message,
        [object]$Data
    )
    $results.Add([pscustomobject]@{
        Timestamp = (Get-Date).ToUniversalTime().ToString('o')
        Phase     = $Phase
        Status    = $Status
        Message   = $Message
        Data      = $Data
    })
    $color = switch ($Status) { 'Pass' {'Green'} 'Warn' {'Yellow'} 'Fail' {'Red'} default {'Cyan'} }
    Write-Host "[$Status] $Phase :: $Message" -ForegroundColor $color
}

Write-Host '--- Starting Targeted Cluster Validation ---' -ForegroundColor Cyan
Write-Host "Nodes       : $($Nodes -join ', ')"
Write-Host "Expected    : $ExpectedDiskCount shared disks per node"
Write-Host "HTML Report : $htmlReport"
Write-Host "JSON Report : $jsonReport"
Write-Host ''

# ---------------------------------------------------------------------------
# Phase 1: Pre-Flight - Module availability and node reachability
# ---------------------------------------------------------------------------
foreach ($mod in 'FailoverClusters', 'MPIO') {
    if (Get-Module -ListAvailable -Name $mod) {
        Add-Result -Phase 'PreFlight' -Status 'Pass' -Message "Module '$mod' is available."
    } else {
        Add-Result -Phase 'PreFlight' -Status 'Fail' -Message "Module '$mod' is missing on the local host."
    }
}

$reachable = foreach ($node in $Nodes) {
    if (Test-Connection -ComputerName $node -Count 1 -Quiet -ErrorAction SilentlyContinue) {
        Add-Result -Phase 'PreFlight' -Status 'Pass' -Message "Node '$node' responds to ICMP."
        $node
    } else {
        Add-Result -Phase 'PreFlight' -Status 'Fail' -Message "Node '$node' is unreachable; excluded from remote phases."
    }
}

if ($reachable.Count -lt 2) {
    Add-Result -Phase 'PreFlight' -Status 'Fail' -Message 'Fewer than two nodes reachable; aborting.'
    $results | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonReport
    throw 'Insufficient reachable nodes to perform cluster validation.'
}

# ---------------------------------------------------------------------------
# Phase 2: MPIO Global Claim - verifies the local DSM is configured
# ---------------------------------------------------------------------------
try {
    $mpioPolicy = Get-MSDSMGlobalDefaultLoadBalancePolicy -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($mpioPolicy) -or $mpioPolicy -eq 'None') {
        Add-Result -Phase 'MPIO' -Status 'Warn' `
            -Message 'No global MPIO load-balance policy is set; multipath LUNs may surface as duplicate disks.' `
            -Data @{ Policy = $mpioPolicy }
    } else {
        Add-Result -Phase 'MPIO' -Status 'Pass' `
            -Message "Global MPIO load-balance policy = $mpioPolicy." `
            -Data @{ Policy = $mpioPolicy }
    }
} catch {
    Add-Result -Phase 'MPIO' -Status 'Warn' -Message "MPIO interrogation failed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# Phase 3: Storage Inventory - every node must see ExpectedDiskCount LUNs
# ---------------------------------------------------------------------------
$diskInventory = @{}
foreach ($node in $reachable) {
    try {
        $remote = Invoke-Command -ComputerName $node -ErrorAction Stop -ScriptBlock {
            $disks = Get-Disk | Where-Object Number -ne 0
            [pscustomobject]@{
                ComputerName = $env:COMPUTERNAME
                Count        = ($disks | Measure-Object).Count
                Serials      = ($disks | Select-Object -ExpandProperty SerialNumber -ErrorAction SilentlyContinue) -join ','
            }
        }
        $diskInventory[$node] = $remote

        if ($remote.Count -eq $ExpectedDiskCount) {
            Add-Result -Phase 'Storage' -Status 'Pass' `
                -Message "$node sees $($remote.Count) shared disks (expected $ExpectedDiskCount)." `
                -Data $remote
        } else {
            Add-Result -Phase 'Storage' -Status 'Fail' `
                -Message "$node sees $($remote.Count) shared disks (expected $ExpectedDiskCount)." `
                -Data $remote
        }
    } catch {
        Add-Result -Phase 'Storage' -Status 'Fail' `
            -Message "Disk enumeration failed on $node : $($_.Exception.Message)"
    }
}

# Cross-node serial-number consistency: every reachable node should see the
# identical set of LUN serials. A mismatch signals a zoning or LUN-masking gap.
$serialSets = $diskInventory.Values | Where-Object { $_.Serials } | Select-Object -ExpandProperty Serials -Unique
if ($serialSets.Count -le 1) {
    Add-Result -Phase 'Storage' -Status 'Pass' -Message 'All reachable nodes report an identical LUN serial set.'
} else {
    Add-Result -Phase 'Storage' -Status 'Fail' `
        -Message 'Nodes report divergent LUN serial sets; verify SAN zoning and host masking.' `
        -Data @{ DistinctSets = $serialSets.Count }
}

# ---------------------------------------------------------------------------
# Phase 4: SCSI-3 Persistent Reservation state via the cluster API
# ---------------------------------------------------------------------------
# We deliberately avoid raw SCSI PR commands. Instead we read the cluster's
# own reservation bookkeeping: any clustered physical disk resource that is
# 'Online' is, by definition, holding a PR_RESERVE on its LUN; any disk
# stuck in 'Failed' or perpetually 'OnlinePending' indicates a reservation
# conflict or fencing failure.
try {
    $clusterDisks = Invoke-Command -ComputerName $reachable[0] -ErrorAction Stop -ScriptBlock {
        Import-Module FailoverClusters -ErrorAction Stop
        Get-ClusterResource | Where-Object ResourceType -in 'Physical Disk', 'Cluster Shared Volume' |
            Select-Object Name, OwnerNode, State, ResourceType
    }

    foreach ($cd in $clusterDisks) {
        switch ($cd.State) {
            'Online' {
                Add-Result -Phase 'SCSI3' -Status 'Pass' `
                    -Message "$($cd.Name) is Online on $($cd.OwnerNode); reservation held cleanly." `
                    -Data $cd
            }
            'Failed' {
                Add-Result -Phase 'SCSI3' -Status 'Fail' `
                    -Message "$($cd.Name) is Failed; probable SCSI-3 reservation conflict or fencing failure." `
                    -Data $cd
            }
            default {
                Add-Result -Phase 'SCSI3' -Status 'Warn' `
                    -Message "$($cd.Name) state=$($cd.State) on $($cd.OwnerNode); investigate." `
                    -Data $cd
            }
        }
    }
} catch {
    Add-Result -Phase 'SCSI3' -Status 'Fail' `
        -Message "Cluster reservation interrogation failed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# Phase 5: Microsoft Test-Cluster
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Running Test-Cluster (this may take several minutes for 32 disks)...' -ForegroundColor Cyan
try {
    Test-Cluster -Node $reachable `
                 -Include $IncludeTests `
                 -Exclude $ExcludeTests `
                 -ReportName $htmlReport | Out-Null

    Add-Result -Phase 'TestCluster' -Status 'Pass' `
        -Message "Test-Cluster completed; HTML report at $htmlReport." `
        -Data @{ ReportPath = $htmlReport; Included = $IncludeTests; Excluded = $ExcludeTests }
} catch {
    Add-Result -Phase 'TestCluster' -Status 'Fail' `
        -Message "Test-Cluster failed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# Phase 6: Persist results and emit summary
# ---------------------------------------------------------------------------
$results | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonReport -Encoding UTF8

$summary = $results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host ''
Write-Host "--- Validation Complete: $($summary -join ' ') ---" -ForegroundColor Green
Write-Host "HTML : $htmlReport"
Write-Host "JSON : $jsonReport"

if ($WriteEventLog) {
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
            [System.Diagnostics.EventLog]::CreateEventSource($EventSource, $EventLogName)
        }
        $hasFail = $results.Status -contains 'Fail'
        $entryType = if ($hasFail) { 'Error' } else { 'Information' }
        $payload = @{
            Nodes   = $Nodes
            Summary = ($results | Group-Object Status | ForEach-Object { @{ $_.Name = $_.Count } })
            Reports = @{ Html = $htmlReport; Json = $jsonReport }
        } | ConvertTo-Json -Depth 6 -Compress

        Write-EventLog -LogName $EventLogName -Source $EventSource `
            -EventId 4001 -EntryType $entryType -Message $payload
    } catch {
        Write-Warning "Event log emission failed: $($_.Exception.Message)"
    }
}

# Non-zero exit code on any Fail so an SQL Agent CmdExec step or CI pipeline
# can react appropriately.
if ($results.Status -contains 'Fail') { exit 1 } else { exit 0 }
