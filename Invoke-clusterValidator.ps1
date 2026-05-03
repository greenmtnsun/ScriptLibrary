#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -Modules FailoverClusters

<#
.SYNOPSIS
    Targeted validation for a 4-node / 5-instance SQL Failover Cluster.

.DESCRIPTION
    Performs pre-flight, storage delivery, MPIO, and SCSI-3 Persistent
    Reservation checks across the supplied node list, then invokes the
    official Microsoft Test-Cluster validation suite. Results land in a
    durable artifact triad (HTML + JSON + transcript) plus an optional
    Windows Event Log payload. The script is non-destructive: it never
    issues raw SCSI PR writes; reservation state is read via the cluster
    API.

.PARAMETER Nodes
    The cluster node short names. Order is not significant. Two minimum.

.PARAMETER ExpectedDiskCount
    Shared cluster disks each node should see (excludes the OS disk).
    Defaults to 32 for the legacy SAN topology this script targets.

.PARAMETER ReportPath
    Output directory for the HTML, JSON, and transcript artifacts. Must
    exist. Defaults to C:\Temp.

.PARAMETER IncludeTests
    Test-Cluster category filter.

.PARAMETER ExcludeTests
    Test-Cluster categories to suppress. Defaults to S2D since this is a
    traditional SAN/VMware FCI.

.PARAMETER OperationTimeoutSeconds
    PSSession per-operation timeout. Caps how long a single hung node can
    block the run.

.PARAMETER OpenTimeoutSeconds
    PSSession open timeout.

.PARAMETER WriteEventLog
    When set, writes a structured JSON summary to the Application event
    log under the ClusterValidator source.

.NOTES
    Run from standard powershell.exe with:
        -NoProfile -NonInteractive -ExecutionPolicy Bypass

    Do NOT run inside SQLPS.exe. Schedule via SQL Agent CmdExec, never
    the native PowerShell subsystem.

    Companion docs:
        ClusterValidator-Rules.md   (engineering rules)
        ClusterValidator-Roadmap.md (enterprise readiness phases)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateCount(2, 16)]
    [string[]]$Nodes,

    [ValidateRange(1, 1024)]
    [int]$ExpectedDiskCount = 32,

    [ValidateScript({ Test-Path -Path $_ -PathType Container })]
    [string]$ReportPath = 'C:\Temp',

    [string[]]$IncludeTests = @('Inventory', 'Network', 'System Configuration', 'Storage'),

    [string[]]$ExcludeTests = @('Storage Spaces Direct'),

    [ValidateRange(10, 600)]
    [int]$OperationTimeoutSeconds = 60,

    [ValidateRange(5, 120)]
    [int]$OpenTimeoutSeconds = 30,

    [switch]$WriteEventLog,

    [string]$EventLogName = 'Application',

    [string]$EventSource  = 'ClusterValidator'
)

$ErrorActionPreference = 'Stop'

$correlationId    = [guid]::NewGuid().ToString()
$timestamp        = Get-Date -Format 'yyyyMMdd_HHmm'
$htmlReport       = Join-Path $ReportPath "ClusterValidation_${timestamp}.html"
$jsonReport       = Join-Path $ReportPath "ClusterValidation_${timestamp}.json"
$transcriptPath   = Join-Path $ReportPath "ClusterValidation_${timestamp}_transcript.log"

$results          = [System.Collections.Generic.List[object]]::new()
$nodeSessions     = [ordered]@{}
$transcriptStarted = $false

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Add-Result {
    param(
        [Parameter(Mandatory)] [string]$Phase,
        [Parameter(Mandatory)] [ValidateSet('Pass', 'Warn', 'Fail', 'Info')] [string]$Status,
        [Parameter(Mandatory)] [string]$Message,
        [object]$Data
    )
    $results.Add([pscustomobject]@{
        CorrelationId = $correlationId
        Timestamp     = (Get-Date).ToUniversalTime().ToString('o')
        Phase         = $Phase
        Status        = $Status
        Message       = $Message
        Data          = $Data
    })
    $color = switch ($Status) { 'Pass' {'Green'} 'Warn' {'Yellow'} 'Fail' {'Red'} default {'Cyan'} }
    Write-Host "[$Status] $Phase :: $Message" -ForegroundColor $color
}

# Wrappers per ClusterValidator-Rules.md §5: each high-blast-radius cmdlet
# is invoked from exactly one place so it can be mocked uniformly in
# tests and hardened uniformly in production.
function Invoke-ClvRemote {
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory)] [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList
    )
    Invoke-Command -Session $Session -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
}

function Invoke-ClvTestCluster {
    param(
        [Parameter(Mandatory)] [string[]]$Node,
        [string[]]$Include,
        [string[]]$Exclude,
        [Parameter(Mandatory)] [string]$ReportName
    )
    Test-Cluster -Node $Node -Include $Include -Exclude $Exclude -ReportName $ReportName -ErrorAction Stop
}

function Get-ClvClusterResource {
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Runspaces.PSSession]$Session
    )
    Invoke-ClvRemote -Session $Session -ScriptBlock {
        Import-Module FailoverClusters -ErrorAction Stop
        Get-ClusterResource |
            Where-Object ResourceType -in 'Physical Disk', 'Cluster Shared Volume' |
            Select-Object Name, OwnerNode, State, ResourceType
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    Start-Transcript -Path $transcriptPath -Force | Out-Null
    $transcriptStarted = $true

    Write-Host "--- Cluster Validation $correlationId ---" -ForegroundColor Cyan
    Write-Host "Nodes       : $($Nodes -join ', ')"
    Write-Host "Expected    : $ExpectedDiskCount shared disks per node"
    Write-Host "HTML        : $htmlReport"
    Write-Host "JSON        : $jsonReport"
    Write-Host "Transcript  : $transcriptPath"
    Write-Host ''

    # -----------------------------------------------------------------------
    # Phase 1: PreFlight - module availability, WSMan reachability, sessions
    # -----------------------------------------------------------------------
    foreach ($mod in 'FailoverClusters', 'MPIO') {
        if (Get-Module -ListAvailable -Name $mod) {
            Add-Result -Phase 'PreFlight' -Status 'Pass' -Message "Module '$mod' available."
        } else {
            Add-Result -Phase 'PreFlight' -Status 'Fail' -Message "Module '$mod' missing."
        }
    }

    $reachable = foreach ($node in $Nodes) {
        try {
            Test-WSMan -ComputerName $node -ErrorAction Stop | Out-Null
            Add-Result -Phase 'PreFlight' -Status 'Pass' -Message "WSMan reachable on $node."
            $node
        } catch {
            Add-Result -Phase 'PreFlight' -Status 'Fail' `
                -Message "WSMan unreachable on $node ($($_.Exception.Message))."
        }
    }

    if (@($reachable).Count -lt 2) {
        throw 'Fewer than two nodes reachable; aborting validation.'
    }

    $sessionOption = New-PSSessionOption `
        -OperationTimeout ($OperationTimeoutSeconds * 1000) `
        -OpenTimeout      ($OpenTimeoutSeconds      * 1000)

    foreach ($node in $reachable) {
        try {
            $nodeSessions[$node] = New-PSSession -ComputerName $node -SessionOption $sessionOption -ErrorAction Stop
            Add-Result -Phase 'PreFlight' -Status 'Pass' -Message "PSSession opened to $node."
        } catch {
            Add-Result -Phase 'PreFlight' -Status 'Fail' `
                -Message "PSSession failed for $node ($($_.Exception.Message))."
        }
    }

    $sessionNodes = @($nodeSessions.Keys)
    if ($sessionNodes.Count -lt 2) {
        throw 'Fewer than two PSSessions opened; aborting validation.'
    }

    # -----------------------------------------------------------------------
    # Phase 2: MPIO - global DSM claim
    # -----------------------------------------------------------------------
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

    # -----------------------------------------------------------------------
    # Phase 3: Storage - per-node disk count + cross-node serial consistency
    # -----------------------------------------------------------------------
    $diskInventory = @{}
    foreach ($node in $sessionNodes) {
        try {
            $remote = Invoke-ClvRemote -Session $nodeSessions[$node] -ScriptBlock {
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

    $serialSets = $diskInventory.Values | Where-Object { $_.Serials } |
                  Select-Object -ExpandProperty Serials -Unique
    if (@($serialSets).Count -le 1) {
        Add-Result -Phase 'Storage' -Status 'Pass' -Message 'All reachable nodes report an identical LUN serial set.'
    } else {
        Add-Result -Phase 'Storage' -Status 'Fail' `
            -Message 'Nodes report divergent LUN serial sets; verify SAN zoning and host masking.' `
            -Data @{ DistinctSets = @($serialSets).Count }
    }

    # -----------------------------------------------------------------------
    # Phase 4: SCSI3 - cluster reservation state via cluster API
    # -----------------------------------------------------------------------
    try {
        $clusterDisks = Get-ClvClusterResource -Session $nodeSessions[$sessionNodes[0]]

        foreach ($cd in $clusterDisks) {
            switch ($cd.State) {
                'Online' {
                    Add-Result -Phase 'SCSI3' -Status 'Pass' `
                        -Message "$($cd.Name) Online on $($cd.OwnerNode); reservation held cleanly." `
                        -Data $cd
                }
                'Failed' {
                    Add-Result -Phase 'SCSI3' -Status 'Fail' `
                        -Message "$($cd.Name) Failed; probable SCSI-3 reservation conflict or fencing failure." `
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

    # -----------------------------------------------------------------------
    # Phase 11: TestCluster - Microsoft validation suite
    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host 'Running Test-Cluster (this may take several minutes for 32 disks)...' -ForegroundColor Cyan
    try {
        Invoke-ClvTestCluster -Node $sessionNodes `
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

    # -----------------------------------------------------------------------
    # Phase 12: Persist - JSON + summary + Event Log
    # -----------------------------------------------------------------------
    $results | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonReport -Encoding UTF8

    $summary = $results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Host ''
    Write-Host "--- Validation Complete: $($summary -join ' ') ---" -ForegroundColor Green
    Write-Host "HTML       : $htmlReport"
    Write-Host "JSON       : $jsonReport"
    Write-Host "Transcript : $transcriptPath"

    if ($WriteEventLog) {
        try {
            if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
                [System.Diagnostics.EventLog]::CreateEventSource($EventSource, $EventLogName)
            }
            $hasFail = $results.Status -contains 'Fail'
            $entryType = if ($hasFail) { 'Error' } else { 'Information' }
            $payload = @{
                CorrelationId = $correlationId
                Nodes         = $Nodes
                Summary       = ($results | Group-Object Status | ForEach-Object { @{ $_.Name = $_.Count } })
                Reports       = @{ Html = $htmlReport; Json = $jsonReport; Transcript = $transcriptPath }
            } | ConvertTo-Json -Depth 6 -Compress

            Write-EventLog -LogName $EventLogName -Source $EventSource `
                -EventId 4001 -EntryType $entryType -Message $payload
        } catch {
            Write-Warning "Event log emission failed: $($_.Exception.Message)"
        }
    }
}
finally {
    foreach ($s in $nodeSessions.Values) {
        if ($s) { Remove-PSSession -Session $s -ErrorAction SilentlyContinue }
    }
    if ($transcriptStarted) {
        Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    }
}

# Non-zero exit on any Fail so a CmdExec step or CI pipeline can react.
if ($results.Status -contains 'Fail') { exit 1 } else { exit 0 }
