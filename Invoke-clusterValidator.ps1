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

    Production hardening expectations (roadmap Phase 3):
      - the script is signed with the internal PKI cert and the host
        execution policy is AllSigned
      - the executing principal is a Group Managed Service Account whose
        SQL login holds SQLAgentReaderRole + VIEW SERVER STATE only
      - the remoting credential is resolved via -CredentialSecretName
        backed by Microsoft.PowerShell.SecretManagement, never inline
        plaintext
      - -HardenReportAcl is set so the artifact triad inherits a DACL
        of SYSTEM + Administrators only (the JSON contains LUN serials,
        node topology, and service-account names)
      - the host enforces FullLanguage mode for this script via
        WDAC/AppLocker allowlist; Constrained Language Mode is a hard
        fail by design

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

    [ValidateSet('NodeMajority', 'NodeAndDiskMajority', 'NodeAndFileShareMajority',
                 'NodeAndCloudMajority', 'DiskOnly', '')]
    [string]$ExpectedQuorumType = '',

    [ValidateRange(0.1, 60.0)]
    [double]$TimeSkewToleranceSeconds = 2.0,

    [ValidateRange(5, 1440)]
    [int]$ForensicCaptureMinutes = 60,

    # Phase 3: security hardening
    [PSCredential]$Credential,

    [string]$CredentialSecretName,

    [switch]$HardenReportAcl,

    [switch]$WriteEventLog,

    [string]$EventLogName = 'Application',

    [string]$EventSource  = 'ClusterValidator'
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Phase 3 synchronous preflight - fail fast, BEFORE the transcript opens.
# Anything that legitimately fails here means the run shouldn't start, and
# we want the error visible on stderr without a half-written transcript.
# ---------------------------------------------------------------------------

# Constrained Language Mode is a hard fail. The validation script needs
# .NET reflection (FileSystemAccessRule, EventLog) and complex AST work
# that CLM blocks. Allowlist via WDAC/AppLocker for production hosts.
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    throw "ConfigurationError: cluster validator requires FullLanguage mode (current: $($ExecutionContext.SessionState.LanguageMode)). Allowlist this script via WDAC/AppLocker, or run from a FullLanguage host."
}

# Resolve credentials from SecretManagement if -CredentialSecretName was
# given without a literal -Credential. Plaintext passwords in script text
# are a non-starter under ClusterValidator-Rules.md.
if (-not $Credential -and $CredentialSecretName) {
    if (-not (Get-Module -ListAvailable -Name Microsoft.PowerShell.SecretManagement)) {
        throw "ConfigurationError: -CredentialSecretName '$CredentialSecretName' was specified but the Microsoft.PowerShell.SecretManagement module is not installed."
    }
    Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop
    try {
        $Credential = Get-Secret -Name $CredentialSecretName -ErrorAction Stop
    } catch {
        throw "ConfigurationError: failed to resolve secret '$CredentialSecretName' from the SecretManagement vault: $($_.Exception.Message)"
    }
    if ($Credential -isnot [PSCredential]) {
        throw "ConfigurationError: secret '$CredentialSecretName' did not resolve to a PSCredential."
    }
}

# Optional report-directory ACL hardening. Runs BEFORE Start-Transcript so
# the transcript file inherits the locked-down DACL.
if ($HardenReportAcl) {
    try {
        $acl = Get-Acl -Path $ReportPath
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) {
            $acl.RemoveAccessRule($rule) | Out-Null
        }
        foreach ($identity in 'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators') {
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $identity,
                'FullControl',
                'ContainerInherit,ObjectInherit',
                'None',
                'Allow')))
        }
        Set-Acl -Path $ReportPath -AclObject $acl
    } catch {
        throw "ConfigurationError: failed to harden ACL on '$ReportPath' - $($_.Exception.Message)"
    }
}

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
    [CmdletBinding(DefaultParameterSetName = 'Single')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Single')]
        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory, ParameterSetName = 'Many')]
        [System.Management.Automation.Runspaces.PSSession[]]$Sessions,

        [Parameter(Mandatory)] [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList
    )
    if ($PSCmdlet.ParameterSetName -eq 'Many') {
        Invoke-Command -Session $Sessions -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
    } else {
        Invoke-Command -Session $Session  -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
    }
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

    if ($Credential) {
        Add-Result -Phase 'PreFlight' -Status 'Info' `
            -Message "Using explicit credential for principal '$($Credential.UserName)'."
    } else {
        Add-Result -Phase 'PreFlight' -Status 'Info' `
            -Message 'Using ambient (current-user) credential for remoting.'
    }

    foreach ($node in $reachable) {
        $sessionParams = @{
            ComputerName  = $node
            SessionOption = $sessionOption
            ErrorAction   = 'Stop'
        }
        if ($Credential) { $sessionParams.Credential = $Credential }

        try {
            $nodeSessions[$node] = New-PSSession @sessionParams
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
    # Phase 5: Quorum - witness state and quorum type
    # -----------------------------------------------------------------------
    try {
        $quorum = Invoke-ClvRemote -Session $nodeSessions[$sessionNodes[0]] -ScriptBlock {
            Import-Module FailoverClusters -ErrorAction Stop
            $q = Get-ClusterQuorum
            [pscustomobject]@{
                QuorumType     = "$($q.QuorumType)"
                QuorumResource = if ($q.QuorumResource) { $q.QuorumResource.Name }  else { $null }
                ResourceState  = if ($q.QuorumResource) { "$($q.QuorumResource.State)" } else { $null }
            }
        }

        if ($ExpectedQuorumType -and $quorum.QuorumType -ne $ExpectedQuorumType) {
            Add-Result -Phase 'Quorum' -Status 'Fail' `
                -Message "Quorum type is $($quorum.QuorumType); expected $ExpectedQuorumType." `
                -Data $quorum
        } elseif ($quorum.QuorumResource -and $quorum.ResourceState -ne 'Online') {
            Add-Result -Phase 'Quorum' -Status 'Fail' `
                -Message "Quorum witness '$($quorum.QuorumResource)' state=$($quorum.ResourceState)." `
                -Data $quorum
        } else {
            Add-Result -Phase 'Quorum' -Status 'Pass' `
                -Message "Quorum type=$($quorum.QuorumType); witness='$($quorum.QuorumResource)' is healthy." `
                -Data $quorum
        }
    } catch {
        Add-Result -Phase 'Quorum' -Status 'Fail' `
            -Message "Quorum interrogation failed: $($_.Exception.Message)"
    }

    # -----------------------------------------------------------------------
    # Phase 6: Heartbeat - cluster network thresholds
    # -----------------------------------------------------------------------
    try {
        $hb = Invoke-ClvRemote -Session $nodeSessions[$sessionNodes[0]] -ScriptBlock {
            Import-Module FailoverClusters -ErrorAction Stop
            Get-Cluster | Select-Object Name,
                SameSubnetThreshold,  SameSubnetDelay,
                CrossSubnetThreshold, CrossSubnetDelay,
                RouteHistoryLength
        }
        # Server 2016+ defaults: Same=10/1000ms, Cross=20/1000ms, Route=10
        # Below-default thresholds make the cluster sensitive to transient
        # network blips and cause spurious failovers.
        if ($hb.SameSubnetThreshold -lt 10 -or $hb.CrossSubnetThreshold -lt 20) {
            Add-Result -Phase 'Heartbeat' -Status 'Warn' `
                -Message "Heartbeat thresholds below default (Same=$($hb.SameSubnetThreshold), Cross=$($hb.CrossSubnetThreshold))." `
                -Data $hb
        } else {
            Add-Result -Phase 'Heartbeat' -Status 'Pass' `
                -Message "Heartbeat thresholds at or above default (Same=$($hb.SameSubnetThreshold), Cross=$($hb.CrossSubnetThreshold))." `
                -Data $hb
        }
    } catch {
        Add-Result -Phase 'Heartbeat' -Status 'Warn' `
            -Message "Heartbeat config interrogation failed: $($_.Exception.Message)"
    }

    # -----------------------------------------------------------------------
    # Phase 7: Time - cross-node W32Time skew
    # -----------------------------------------------------------------------
    try {
        $samples = Invoke-ClvRemote -Sessions @($nodeSessions.Values) -ScriptBlock {
            [pscustomobject]@{
                ComputerName = $env:COMPUTERNAME
                UtcNow       = (Get-Date).ToUniversalTime()
            }
        }
        $valid = @($samples | Where-Object { $_.UtcNow })
        if ($valid.Count -ge 2) {
            $min  = ($valid.UtcNow | Measure-Object -Minimum).Minimum
            $max  = ($valid.UtcNow | Measure-Object -Maximum).Maximum
            $skew = [math]::Round(($max - $min).TotalSeconds, 3)
            if ($skew -gt $TimeSkewToleranceSeconds) {
                Add-Result -Phase 'Time' -Status 'Fail' `
                    -Message "Cross-node time skew is ${skew}s; tolerance is ${TimeSkewToleranceSeconds}s." `
                    -Data $valid
            } else {
                Add-Result -Phase 'Time' -Status 'Pass' `
                    -Message "Cross-node time skew is ${skew}s (within ${TimeSkewToleranceSeconds}s)." `
                    -Data $valid
            }
        } else {
            Add-Result -Phase 'Time' -Status 'Warn' `
                -Message 'Insufficient time samples to evaluate skew.'
        }
    } catch {
        Add-Result -Phase 'Time' -Status 'Warn' `
            -Message "Time interrogation failed: $($_.Exception.Message)"
    }

    # -----------------------------------------------------------------------
    # Phase 8: Reboot - pending-reboot detection on every node
    # -----------------------------------------------------------------------
    try {
        $reboots = Invoke-ClvRemote -Sessions @($nodeSessions.Values) -ScriptBlock {
            $reasons = [System.Collections.Generic.List[string]]::new()
            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
                $reasons.Add('CBS')
            }
            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
                $reasons.Add('WindowsUpdate')
            }
            $sm = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
                -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
            if ($sm.PendingFileRenameOperations) {
                $reasons.Add('PendingFileRenameOperations')
            }
            [pscustomobject]@{ ComputerName = $env:COMPUTERNAME; Reasons = $reasons.ToArray() }
        }
        foreach ($n in $reboots) {
            if ($n.Reasons.Count -gt 0) {
                Add-Result -Phase 'Reboot' -Status 'Fail' `
                    -Message "$($n.ComputerName) has pending reboot ($($n.Reasons -join ', '))." `
                    -Data $n
            } else {
                Add-Result -Phase 'Reboot' -Status 'Pass' `
                    -Message "$($n.ComputerName) has no pending reboot." `
                    -Data $n
            }
        }
    } catch {
        Add-Result -Phase 'Reboot' -Status 'Warn' `
            -Message "Reboot interrogation failed: $($_.Exception.Message)"
    }

    # -----------------------------------------------------------------------
    # Phase 9: Hotfix - KB parity across nodes
    # -----------------------------------------------------------------------
    try {
        $hotfixes = Invoke-ClvRemote -Sessions @($nodeSessions.Values) -ScriptBlock {
            [pscustomobject]@{
                ComputerName = $env:COMPUTERNAME
                HotFixIDs    = @(Get-HotFix | Sort-Object HotFixID | Select-Object -ExpandProperty HotFixID)
            }
        }
        $allKbs = $hotfixes.HotFixIDs | Sort-Object -Unique
        $drift = foreach ($n in $hotfixes) {
            $absent = @($allKbs | Where-Object { $_ -notin $n.HotFixIDs })
            if ($absent.Count -gt 0) {
                [pscustomobject]@{ ComputerName = $n.ComputerName; Missing = $absent }
            }
        }
        if ($drift) {
            Add-Result -Phase 'Hotfix' -Status 'Warn' `
                -Message 'Hotfix drift detected across nodes.' -Data $drift
        } else {
            $kbCount = @($allKbs).Count
            Add-Result -Phase 'Hotfix' -Status 'Pass' `
                -Message "All nodes share an identical KB level ($kbCount KBs)."
        }
    } catch {
        Add-Result -Phase 'Hotfix' -Status 'Warn' `
            -Message "Hotfix interrogation failed: $($_.Exception.Message)"
    }

    # -----------------------------------------------------------------------
    # Phase 10: ServiceAccount - Cluster + SQL service account hygiene
    # -----------------------------------------------------------------------
    try {
        $svcAccounts = Invoke-ClvRemote -Sessions @($nodeSessions.Values) -ScriptBlock {
            $svcs = Get-CimInstance -ClassName Win32_Service `
                -Filter "Name='ClusSvc' OR Name LIKE 'MSSQL%' OR Name LIKE 'SQLAgent%'" |
                Select-Object Name, StartName, State
            [pscustomobject]@{ ComputerName = $env:COMPUTERNAME; Services = $svcs }
        }
        $builtIn = @('LocalSystem', 'NT AUTHORITY\LocalService', 'NT AUTHORITY\NetworkService')
        $issues = New-Object System.Collections.Generic.List[object]

        foreach ($n in $svcAccounts) {
            foreach ($svc in $n.Services) {
                if ($svc.StartName -in $builtIn) {
                    $issues.Add([pscustomobject]@{
                        ComputerName = $n.ComputerName
                        Service      = $svc.Name
                        StartName    = $svc.StartName
                        Issue        = 'BuiltInAccount'
                    })
                }
            }
        }

        $serviceMap = @{}
        foreach ($n in $svcAccounts) {
            foreach ($svc in $n.Services) {
                if (-not $serviceMap.ContainsKey($svc.Name)) { $serviceMap[$svc.Name] = @{} }
                $serviceMap[$svc.Name][$n.ComputerName] = $svc.StartName
            }
        }
        foreach ($svcName in $serviceMap.Keys) {
            $accounts = $serviceMap[$svcName].Values | Sort-Object -Unique
            if (@($accounts).Count -gt 1) {
                $issues.Add([pscustomobject]@{
                    Service  = $svcName
                    Accounts = $serviceMap[$svcName]
                    Issue    = 'AccountMismatch'
                })
            }
        }

        if ($issues.Count -gt 0) {
            Add-Result -Phase 'ServiceAccount' -Status 'Warn' `
                -Message 'Service account hygiene issues detected.' -Data $issues
        } else {
            Add-Result -Phase 'ServiceAccount' -Status 'Pass' `
                -Message 'All cluster/SQL service accounts are uniform and non-builtin.'
        }
    } catch {
        Add-Result -Phase 'ServiceAccount' -Status 'Warn' `
            -Message "ServiceAccount interrogation failed: $($_.Exception.Message)"
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
    # Phase 12: Forensic - Get-ClusterLog capture, only on Fail
    # -----------------------------------------------------------------------
    if ($results.Status -contains 'Fail') {
        try {
            Get-ClusterLog -Destination $ReportPath -TimeSpan $ForensicCaptureMinutes -ErrorAction Stop | Out-Null
            Add-Result -Phase 'Forensic' -Status 'Info' `
                -Message "Cluster log captured to $ReportPath (last $ForensicCaptureMinutes minutes)."
        } catch {
            Add-Result -Phase 'Forensic' -Status 'Warn' `
                -Message "Cluster log capture failed: $($_.Exception.Message)"
        }
    } else {
        Add-Result -Phase 'Forensic' -Status 'Info' `
            -Message 'No failures detected; forensic capture skipped.'
    }

    # -----------------------------------------------------------------------
    # Phase 13: Persist - JSON + summary + Event Log
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
