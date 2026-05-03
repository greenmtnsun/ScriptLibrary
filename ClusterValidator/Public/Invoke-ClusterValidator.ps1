function Invoke-ClusterValidator {
<#
.SYNOPSIS
    Targeted validation for a multi-node SQL Failover Cluster.

.DESCRIPTION
    Performs pre-flight, storage delivery, MPIO, SCSI-3 reservation,
    quorum, heartbeat, time-skew, pending-reboot, hotfix parity, and
    service-account hygiene checks across the supplied node list, then
    invokes the official Microsoft Test-Cluster validation suite.
    Results land in a durable artifact triad (HTML + JSON + transcript)
    plus an optional Windows Event Log payload, and on any Fail the
    cluster log is captured automatically.

    Non-destructive: never issues raw SCSI PR writes or any
    cluster-mutating cmdlet.

.NOTES
    Run from standard powershell.exe with:
        -NoProfile -NonInteractive -ExecutionPolicy Bypass

    Do NOT run inside SQLPS.exe. Schedule via SQL Agent CmdExec, never
    the native PowerShell subsystem.

    Production hardening expectations:
      - module signed with the internal PKI cert; host execution policy
        set to AllSigned
      - executing principal is a Group Managed Service Account whose
        SQL login holds SQLAgentReaderRole + VIEW SERVER STATE only
      - remoting credential resolved via -CredentialSecretName backed by
        Microsoft.PowerShell.SecretManagement, never inline plaintext
      - -HardenReportAcl set so the artifact triad inherits a DACL of
        SYSTEM + Administrators only
      - host enforces FullLanguage mode via WDAC/AppLocker allowlist;
        Constrained Language Mode is a hard fail by design

    Companion docs:
        ClusterValidator-Rules.md   (engineering rules)
        ClusterValidator-Roadmap.md (enterprise readiness phases)

.EXAMPLE
    Invoke-ClusterValidator -Nodes 'sql01','sql02','sql03','sql04' `
                            -ConfigPath '.\Config\prod-cluster-01.json' `
                            -CredentialSecretName 'ClusterValidator' `
                            -HardenReportAcl `
                            -WriteEventLog
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

        [PSCredential]$Credential,

        [string]$CredentialSecretName,

        [switch]$HardenReportAcl,

        # Phase 11 VMware anti-affinity check (optional). When omitted,
        # the phase logs an Info record and skips. PowerCLI must be
        # installed; module is loaded lazily so a missing module is also
        # a clean skip rather than a hard import failure.
        [string]$VCenterServer,

        [string]$VCenterCredentialSecretName,

        [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
        [string]$ConfigPath,

        [switch]$WriteEventLog,

        [string]$EventLogName = 'Application',

        [string]$EventSource  = 'ClusterValidator'
    )

    $ErrorActionPreference = 'Stop'

    # -----------------------------------------------------------------------
    # Runtime admin check (#Requires -RunAsAdministrator only fires when
    # this file is executed as a script; here it's dot-sourced by the
    # module loader, so we enforce it ourselves).
    # -----------------------------------------------------------------------
    $principal = [System.Security.Principal.WindowsPrincipal]::new(
                     [System.Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'ConfigurationError: Invoke-ClusterValidator requires elevated (Administrator) execution context.'
    }

    # -----------------------------------------------------------------------
    # Phase 4 config-file merge - runs first so subsequent preflights see
    # the resolved values. CLI args (anything in $PSBoundParameters) always
    # win; only unspecified parameters fall through. Nodes, Credential,
    # and ConfigPath itself are never config-overridable.
    # -----------------------------------------------------------------------
    $ConfigMergedKeys = @()
    if ($ConfigPath) {
        try {
            $configData = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "ConfigurationError: failed to parse config file '$ConfigPath' - $($_.Exception.Message)"
        }
        $protectedKeys = 'Nodes', 'Credential', 'ConfigPath'
        foreach ($prop in $configData.PSObject.Properties) {
            if ($prop.Name -in $protectedKeys) { continue }
            if ($PSBoundParameters.ContainsKey($prop.Name)) { continue }
            Set-Variable -Name $prop.Name -Value $prop.Value -Scope 0
            $ConfigMergedKeys += $prop.Name
        }
    }

    # -----------------------------------------------------------------------
    # Phase 3 synchronous preflight - fail fast, BEFORE the transcript opens.
    # -----------------------------------------------------------------------
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        throw "ConfigurationError: cluster validator requires FullLanguage mode (current: $($ExecutionContext.SessionState.LanguageMode)). Allowlist this module via WDAC/AppLocker, or run from a FullLanguage host."
    }

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

    # -----------------------------------------------------------------------
    # Module-scope state shared with private helpers (Add-ClvResult, etc.)
    # -----------------------------------------------------------------------
    $script:correlationId = [guid]::NewGuid().ToString()
    $script:results       = [System.Collections.Generic.List[object]]::new()
    $script:nodeSessions  = [ordered]@{}

    $timestamp        = Get-Date -Format 'yyyyMMdd_HHmm'
    $htmlReport       = Join-Path $ReportPath "ClusterValidation_${timestamp}.html"
    $jsonReport       = Join-Path $ReportPath "ClusterValidation_${timestamp}.json"
    $transcriptPath   = Join-Path $ReportPath "ClusterValidation_${timestamp}_transcript.log"
    $transcriptStarted = $false

    try {
        Start-Transcript -Path $transcriptPath -Force | Out-Null
        $transcriptStarted = $true

        Write-Host "--- Cluster Validation $($script:correlationId) ---" -ForegroundColor Cyan
        Write-Host "Nodes       : $($Nodes -join ', ')"
        Write-Host "Expected    : $ExpectedDiskCount shared disks per node"
        Write-Host "HTML        : $htmlReport"
        Write-Host "JSON        : $jsonReport"
        Write-Host "Transcript  : $transcriptPath"
        Write-Host ''

        # -------------------------------------------------------------------
        # Phase 1: PreFlight - module availability, WSMan reachability, sessions
        # -------------------------------------------------------------------
        if ($ConfigPath) {
            if ($ConfigMergedKeys.Count -gt 0) {
                Add-ClvResult -Phase 'PreFlight' -Status 'Info' `
                    -Message "Config '$ConfigPath' supplied $($ConfigMergedKeys.Count) parameter(s)." `
                    -Data @{ ConfigPath = $ConfigPath; MergedKeys = $ConfigMergedKeys }
            } else {
                Add-ClvResult -Phase 'PreFlight' -Status 'Info' `
                    -Message "Config '$ConfigPath' loaded but every key was overridden by the command line."
            }
        }

        foreach ($mod in 'FailoverClusters', 'MPIO') {
            if (Get-Module -ListAvailable -Name $mod) {
                Add-ClvResult -Phase 'PreFlight' -Status 'Pass' -Message "Module '$mod' available."
            } else {
                Add-ClvResult -Phase 'PreFlight' -Status 'Fail' -Category 'ModuleMissingError' -Message "Module '$mod' missing."
            }
        }

        $reachable = foreach ($node in $Nodes) {
            try {
                Test-WSMan -ComputerName $node -ErrorAction Stop | Out-Null
                Add-ClvResult -Phase 'PreFlight' -Status 'Pass' -Message "WSMan reachable on $node."
                $node
            } catch {
                Add-ClvResult -Phase 'PreFlight' -Status 'Fail' -Category 'ConnectionError' `
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
            Add-ClvResult -Phase 'PreFlight' -Status 'Info' `
                -Message "Using explicit credential for principal '$($Credential.UserName)'."
        } else {
            Add-ClvResult -Phase 'PreFlight' -Status 'Info' `
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
                $script:nodeSessions[$node] = New-PSSession @sessionParams
                Add-ClvResult -Phase 'PreFlight' -Status 'Pass' -Message "PSSession opened to $node."
            } catch {
                Add-ClvResult -Phase 'PreFlight' -Status 'Fail' -Category 'ConnectionError' `
                    -Message "PSSession failed for $node ($($_.Exception.Message))."
            }
        }

        $sessionNodes = @($script:nodeSessions.Keys)
        if ($sessionNodes.Count -lt 2) {
            throw 'Fewer than two PSSessions opened; aborting validation.'
        }

        # -------------------------------------------------------------------
        # Phase 2: MPIO - global DSM claim
        # -------------------------------------------------------------------
        try {
            $mpioPolicy = Get-MSDSMGlobalDefaultLoadBalancePolicy -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($mpioPolicy) -or $mpioPolicy -eq 'None') {
                Add-ClvResult -Phase 'MPIO' -Status 'Warn' -Category 'MpioConfigurationError' `
                    -Message 'No global MPIO load-balance policy is set; multipath LUNs may surface as duplicate disks.' `
                    -Data @{ Policy = $mpioPolicy }
            } else {
                Add-ClvResult -Phase 'MPIO' -Status 'Pass' `
                    -Message "Global MPIO load-balance policy = $mpioPolicy." `
                    -Data @{ Policy = $mpioPolicy }
            }
        } catch {
            Add-ClvResult -Phase 'MPIO' -Status 'Warn' -Category 'ConnectionError' `
                -Message "MPIO interrogation failed: $($_.Exception.Message)"
        }

        # -------------------------------------------------------------------
        # Phase 3: Storage - per-node disk count + cross-node serial consistency
        # -------------------------------------------------------------------
        try {
            $diskInventory = Invoke-ClvRemote -Sessions @($script:nodeSessions.Values) -ScriptBlock {
                $disks = Get-Disk | Where-Object Number -ne 0
                [pscustomobject]@{
                    ComputerName = $env:COMPUTERNAME
                    Count        = ($disks | Measure-Object).Count
                    Serials      = ($disks | Select-Object -ExpandProperty SerialNumber -ErrorAction SilentlyContinue) -join ','
                }
            }

            foreach ($remote in $diskInventory) {
                if ($remote.Count -eq $ExpectedDiskCount) {
                    Add-ClvResult -Phase 'Storage' -Status 'Pass' `
                        -Message "$($remote.ComputerName) sees $($remote.Count) shared disks (expected $ExpectedDiskCount)." `
                        -Data $remote
                } else {
                    Add-ClvResult -Phase 'Storage' -Status 'Fail' -Category 'StorageInventoryError' `
                        -Message "$($remote.ComputerName) sees $($remote.Count) shared disks (expected $ExpectedDiskCount)." `
                        -Data $remote
                }
            }

            $serialSets = $diskInventory | Where-Object { $_.Serials } |
                          Select-Object -ExpandProperty Serials -Unique
            if (@($serialSets).Count -le 1) {
                Add-ClvResult -Phase 'Storage' -Status 'Pass' -Message 'All reachable nodes report an identical LUN serial set.'
            } else {
                Add-ClvResult -Phase 'Storage' -Status 'Fail' -Category 'StorageTopologyError' `
                    -Message 'Nodes report divergent LUN serial sets; verify SAN zoning and host masking.' `
                    -Data @{ DistinctSets = @($serialSets).Count }
            }
        } catch {
            Add-ClvResult -Phase 'Storage' -Status 'Fail' -Category 'ConnectionError' `
                -Message "Storage interrogation failed: $($_.Exception.Message)"
        }

        # -------------------------------------------------------------------
        # Phase 4: SCSI3 - cluster reservation state via cluster API
        # -------------------------------------------------------------------
        try {
            $clusterDisks = Get-ClvClusterResource -Session $script:nodeSessions[$sessionNodes[0]]

            foreach ($cd in $clusterDisks) {
                switch ($cd.State) {
                    'Online' {
                        Add-ClvResult -Phase 'SCSI3' -Status 'Pass' `
                            -Message "$($cd.Name) Online on $($cd.OwnerNode); reservation held cleanly." `
                            -Data $cd
                    }
                    'Failed' {
                        Add-ClvResult -Phase 'SCSI3' -Status 'Fail' -Category 'ReservationConflict' `
                            -Message "$($cd.Name) Failed; probable SCSI-3 reservation conflict or fencing failure." `
                            -Data $cd
                    }
                    default {
                        Add-ClvResult -Phase 'SCSI3' -Status 'Warn' -Category 'ReservationConflict' `
                            -Message "$($cd.Name) state=$($cd.State) on $($cd.OwnerNode); investigate." `
                            -Data $cd
                    }
                }
            }
        } catch {
            Add-ClvResult -Phase 'SCSI3' -Status 'Fail' -Category 'ConnectionError' `
                -Message "Cluster reservation interrogation failed: $($_.Exception.Message)"
        }

        # -------------------------------------------------------------------
        # Phase 5: Quorum - witness state and quorum type
        # -------------------------------------------------------------------
        try {
            $quorum = Invoke-ClvRemote -Session $script:nodeSessions[$sessionNodes[0]] -ScriptBlock {
                Import-Module FailoverClusters -ErrorAction Stop
                $q = Get-ClusterQuorum
                [pscustomobject]@{
                    QuorumType     = "$($q.QuorumType)"
                    QuorumResource = if ($q.QuorumResource) { $q.QuorumResource.Name }  else { $null }
                    ResourceState  = if ($q.QuorumResource) { "$($q.QuorumResource.State)" } else { $null }
                }
            }

            if ($ExpectedQuorumType -and $quorum.QuorumType -ne $ExpectedQuorumType) {
                Add-ClvResult -Phase 'Quorum' -Status 'Fail' -Category 'QuorumStateError' `
                    -Message "Quorum type is $($quorum.QuorumType); expected $ExpectedQuorumType." `
                    -Data $quorum
            } elseif ($quorum.QuorumResource -and $quorum.ResourceState -ne 'Online') {
                Add-ClvResult -Phase 'Quorum' -Status 'Fail' -Category 'QuorumStateError' `
                    -Message "Quorum witness '$($quorum.QuorumResource)' state=$($quorum.ResourceState)." `
                    -Data $quorum
            } else {
                Add-ClvResult -Phase 'Quorum' -Status 'Pass' `
                    -Message "Quorum type=$($quorum.QuorumType); witness='$($quorum.QuorumResource)' is healthy." `
                    -Data $quorum
            }
        } catch {
            Add-ClvResult -Phase 'Quorum' -Status 'Fail' -Category 'ConnectionError' `
                -Message "Quorum interrogation failed: $($_.Exception.Message)"
        }

        # -------------------------------------------------------------------
        # Phase 6: Heartbeat - cluster network thresholds
        # -------------------------------------------------------------------
        try {
            $hb = Invoke-ClvRemote -Session $script:nodeSessions[$sessionNodes[0]] -ScriptBlock {
                Import-Module FailoverClusters -ErrorAction Stop
                Get-Cluster | Select-Object Name,
                    SameSubnetThreshold,  SameSubnetDelay,
                    CrossSubnetThreshold, CrossSubnetDelay,
                    RouteHistoryLength
            }
            if ($hb.SameSubnetThreshold -lt 10 -or $hb.CrossSubnetThreshold -lt 20) {
                Add-ClvResult -Phase 'Heartbeat' -Status 'Warn' -Category 'ClusterHeartbeatError' `
                    -Message "Heartbeat thresholds below default (Same=$($hb.SameSubnetThreshold), Cross=$($hb.CrossSubnetThreshold))." `
                    -Data $hb
            } else {
                Add-ClvResult -Phase 'Heartbeat' -Status 'Pass' `
                    -Message "Heartbeat thresholds at or above default (Same=$($hb.SameSubnetThreshold), Cross=$($hb.CrossSubnetThreshold))." `
                    -Data $hb
            }
        } catch {
            Add-ClvResult -Phase 'Heartbeat' -Status 'Warn' -Category 'ConnectionError' `
                -Message "Heartbeat config interrogation failed: $($_.Exception.Message)"
        }

        # -------------------------------------------------------------------
        # Phase 7: Time - cross-node W32Time skew
        # -------------------------------------------------------------------
        try {
            $samples = Invoke-ClvRemote -Sessions @($script:nodeSessions.Values) -ScriptBlock {
                [pscustomobject]@{
                    ComputerName = $env:COMPUTERNAME
                    UtcNow       = (Get-Date).ToUniversalTime()
                }
            }
            $skewReport = Get-ClvTimeSkew -Samples $samples
            if ($null -eq $skewReport.Skew) {
                Add-ClvResult -Phase 'Time' -Status 'Warn' -Category 'TimeSkewError' `
                    -Message "Insufficient time samples to evaluate skew (got $($skewReport.SampleCount))."
            } elseif ($skewReport.Skew -gt $TimeSkewToleranceSeconds) {
                Add-ClvResult -Phase 'Time' -Status 'Fail' -Category 'TimeSkewError' `
                    -Message "Cross-node time skew is $($skewReport.Skew)s; tolerance is ${TimeSkewToleranceSeconds}s." `
                    -Data $skewReport
            } else {
                Add-ClvResult -Phase 'Time' -Status 'Pass' `
                    -Message "Cross-node time skew is $($skewReport.Skew)s (within ${TimeSkewToleranceSeconds}s)." `
                    -Data $skewReport
            }
        } catch {
            Add-ClvResult -Phase 'Time' -Status 'Warn' -Category 'ConnectionError' `
                -Message "Time interrogation failed: $($_.Exception.Message)"
        }

        # -------------------------------------------------------------------
        # Phase 8: Reboot - pending-reboot detection on every node
        # -------------------------------------------------------------------
        try {
            $reboots = Invoke-ClvRemote -Sessions @($script:nodeSessions.Values) -ScriptBlock {
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
                    Add-ClvResult -Phase 'Reboot' -Status 'Fail' -Category 'PendingRebootDetected' `
                        -Message "$($n.ComputerName) has pending reboot ($($n.Reasons -join ', '))." `
                        -Data $n
                } else {
                    Add-ClvResult -Phase 'Reboot' -Status 'Pass' `
                        -Message "$($n.ComputerName) has no pending reboot." `
                        -Data $n
                }
            }
        } catch {
            Add-ClvResult -Phase 'Reboot' -Status 'Warn' -Category 'ConnectionError' `
                -Message "Reboot interrogation failed: $($_.Exception.Message)"
        }

        # -------------------------------------------------------------------
        # Phase 9: Hotfix - KB parity across nodes
        # -------------------------------------------------------------------
        try {
            $hotfixes = Invoke-ClvRemote -Sessions @($script:nodeSessions.Values) -ScriptBlock {
                [pscustomobject]@{
                    ComputerName = $env:COMPUTERNAME
                    HotFixIDs    = @(Get-HotFix | Sort-Object HotFixID | Select-Object -ExpandProperty HotFixID)
                }
            }
            $driftReport = Get-ClvHotFixDrift -Reports $hotfixes
            if ($driftReport.Drift.Count -gt 0) {
                Add-ClvResult -Phase 'Hotfix' -Status 'Warn' -Category 'HotfixParityError' `
                    -Message 'Hotfix drift detected across nodes.' -Data $driftReport.Drift
            } else {
                Add-ClvResult -Phase 'Hotfix' -Status 'Pass' `
                    -Message "All nodes share an identical KB level ($($driftReport.AllKbCount) KBs)."
            }
        } catch {
            Add-ClvResult -Phase 'Hotfix' -Status 'Warn' -Category 'ConnectionError' `
                -Message "Hotfix interrogation failed: $($_.Exception.Message)"
        }

        # -------------------------------------------------------------------
        # Phase 10: ServiceAccount - Cluster + SQL service account hygiene
        # -------------------------------------------------------------------
        try {
            $svcAccounts = Invoke-ClvRemote -Sessions @($script:nodeSessions.Values) -ScriptBlock {
                $svcs = Get-CimInstance -ClassName Win32_Service `
                    -Filter "Name='ClusSvc' OR Name LIKE 'MSSQL%' OR Name LIKE 'SQLAgent%'" |
                    Select-Object Name, StartName, State
                [pscustomobject]@{ ComputerName = $env:COMPUTERNAME; Services = $svcs }
            }
            $issues = Get-ClvServiceAccountIssues -Reports $svcAccounts
            if (@($issues).Count -gt 0) {
                Add-ClvResult -Phase 'ServiceAccount' -Status 'Warn' -Category 'ServiceAccountError' `
                    -Message 'Service account hygiene issues detected.' -Data $issues
            } else {
                Add-ClvResult -Phase 'ServiceAccount' -Status 'Pass' `
                    -Message 'All cluster/SQL service accounts are uniform and non-builtin.'
            }
        } catch {
            Add-ClvResult -Phase 'ServiceAccount' -Status 'Warn' -Category 'ConnectionError' `
                -Message "ServiceAccount interrogation failed: $($_.Exception.Message)"
        }

        # -------------------------------------------------------------------
        # Phase 11: VMware - DRS anti-affinity check (optional)
        # -------------------------------------------------------------------
        # Three skip cases, all logged as Info: PowerCLI missing,
        # -VCenterServer not given, or vCenter unreachable. None of them
        # fails the run. The phase fires Fail/Warn only when we
        # successfully connected and discovered a real anti-affinity
        # violation.
        if (-not $VCenterServer) {
            Add-ClvResult -Phase 'VMware' -Status 'Info' `
                -Message '-VCenterServer not provided; VMware anti-affinity check skipped.'
        } elseif (-not (Get-Module -ListAvailable -Name 'VMware.VimAutomation.Core')) {
            Add-ClvResult -Phase 'VMware' -Status 'Info' `
                -Message 'VMware.VimAutomation.Core (PowerCLI) not installed; VMware anti-affinity check skipped.'
        } else {
            $vcCred = $null
            if ($VCenterCredentialSecretName) {
                if (-not (Get-Module -ListAvailable -Name Microsoft.PowerShell.SecretManagement)) {
                    Add-ClvResult -Phase 'VMware' -Status 'Warn' -Category 'ConfigurationError' `
                        -Message "-VCenterCredentialSecretName specified but Microsoft.PowerShell.SecretManagement is not installed."
                } else {
                    try {
                        $vcCred = Get-Secret -Name $VCenterCredentialSecretName -ErrorAction Stop
                    } catch {
                        Add-ClvResult -Phase 'VMware' -Status 'Warn' -Category 'ConfigurationError' `
                            -Message "Failed to resolve secret '$VCenterCredentialSecretName': $($_.Exception.Message)"
                    }
                }
            }

            $viConn = $null
            try {
                Import-Module VMware.VimAutomation.Core -ErrorAction Stop

                $connectParams = @{
                    Server      = $VCenterServer
                    ErrorAction = 'Stop'
                }
                if ($vcCred) { $connectParams.Credential = $vcCred }
                $viConn = Connect-VIServer @connectParams

                # Match by short name; nodes are passed as short names but
                # vCenter VMs may carry FQDN or display-name conventions.
                # Best-effort: try short, then like-pattern.
                $vms = foreach ($node in $sessionNodes) {
                    $vm = Get-VM -Name $node -ErrorAction SilentlyContinue
                    if (-not $vm) {
                        $vm = Get-VM -Name "$node*" -ErrorAction SilentlyContinue | Select-Object -First 1
                    }
                    if ($vm) { $vm }
                }

                if (@($vms).Count -lt $sessionNodes.Count) {
                    $missing = @($sessionNodes | Where-Object { $_ -notin @($vms.Name) })
                    Add-ClvResult -Phase 'VMware' -Status 'Warn' -Category 'ConfigurationError' `
                        -Message "Could not locate every node in vCenter (missing: $($missing -join ', ')). Anti-affinity check incomplete." `
                        -Data @{ Found = @($vms.Name); Missing = $missing }
                } else {
                    $colo = Get-ClvHostColocation -VMs $vms
                    if ($colo.IsHealthy) {
                        Add-ClvResult -Phase 'VMware' -Status 'Pass' `
                            -Message "All $($vms.Count) FCI VMs are on distinct ESXi hosts." `
                            -Data $colo.HostMap
                    } else {
                        Add-ClvResult -Phase 'VMware' -Status 'Fail' -Category 'AffinityViolation' `
                            -Message "$(@($colo.Colocated).Count) ESXi host(s) hold multiple FCI VMs; a single host failure can take down the cluster." `
                            -Data $colo.Colocated
                    }

                    # DRS rule presence check. Cluster (the vCenter cluster) is the
                    # parent of the first VMHost. Rule may exist with subset; we
                    # only check that *some* enabled VMAntiAffinity rule mentions
                    # at least two of our VMs.
                    try {
                        $vCluster = $vms[0].VMHost.Parent
                        $rules = Get-DrsRule -Cluster $vCluster -Type VMAntiAffinity -ErrorAction Stop
                        $vmIds = $vms.Id
                        $covering = $rules | Where-Object {
                            $_.Enabled -and (@($_.VMIds | Where-Object { $_ -in $vmIds }).Count -ge 2)
                        }
                        if ($covering) {
                            Add-ClvResult -Phase 'VMware' -Status 'Pass' `
                                -Message "DRS anti-affinity rule(s) cover these VMs: $(@($covering.Name) -join ', ')."
                        } else {
                            Add-ClvResult -Phase 'VMware' -Status 'Warn' -Category 'AffinityViolation' `
                                -Message "No enabled DRS VMAntiAffinity rule covers these FCI VMs; vMotion may colocate them later."
                        }
                    } catch {
                        Add-ClvResult -Phase 'VMware' -Status 'Warn' -Category 'ConnectionError' `
                            -Message "DRS rule interrogation failed: $($_.Exception.Message)"
                    }
                }
            } catch {
                Add-ClvResult -Phase 'VMware' -Status 'Warn' -Category 'ConnectionError' `
                    -Message "VMware interrogation failed: $($_.Exception.Message)"
            } finally {
                if ($viConn) {
                    Disconnect-VIServer -Server $viConn -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
                }
            }
        }

        # -------------------------------------------------------------------
        # Phase 12: TestCluster - Microsoft validation suite
        # -------------------------------------------------------------------
        Write-Host ''
        Write-Host 'Running Test-Cluster (this may take several minutes for 32 disks)...' -ForegroundColor Cyan
        try {
            Invoke-ClvTestCluster -Node $sessionNodes `
                                  -Include $IncludeTests `
                                  -Exclude $ExcludeTests `
                                  -ReportName $htmlReport | Out-Null

            Add-ClvResult -Phase 'TestCluster' -Status 'Pass' `
                -Message "Test-Cluster completed; HTML report at $htmlReport." `
                -Data @{ ReportPath = $htmlReport; Included = $IncludeTests; Excluded = $ExcludeTests }
        } catch {
            Add-ClvResult -Phase 'TestCluster' -Status 'Fail' -Category 'TestClusterFailure' `
                -Message "Test-Cluster failed: $($_.Exception.Message)"
        }

        # -------------------------------------------------------------------
        # Phase 13: Forensic - Get-ClusterLog capture, only on Fail
        # -------------------------------------------------------------------
        if ($script:results.Status -contains 'Fail') {
            try {
                Get-ClusterLog -Destination $ReportPath -TimeSpan $ForensicCaptureMinutes -ErrorAction Stop | Out-Null
                Add-ClvResult -Phase 'Forensic' -Status 'Info' `
                    -Message "Cluster log captured to $ReportPath (last $ForensicCaptureMinutes minutes)."
            } catch {
                Add-ClvResult -Phase 'Forensic' -Status 'Warn' -Category 'ConnectionError' `
                    -Message "Cluster log capture failed: $($_.Exception.Message)"
            }
        } else {
            Add-ClvResult -Phase 'Forensic' -Status 'Info' `
                -Message 'No failures detected; forensic capture skipped.'
        }

        # -------------------------------------------------------------------
        # Phase 14: Persist - JSON + summary + Event Log
        # -------------------------------------------------------------------
        $script:results | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonReport -Encoding UTF8

        $summaryParts = $script:results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
        Write-Host ''
        Write-Host "--- Validation Complete: $($summaryParts -join ' ') ---" -ForegroundColor Green
        Write-Host "HTML       : $htmlReport"
        Write-Host "JSON       : $jsonReport"
        Write-Host "Transcript : $transcriptPath"

        if ($WriteEventLog) {
            try {
                if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
                    [System.Diagnostics.EventLog]::CreateEventSource($EventSource, $EventLogName)
                }
                $hasFail = $script:results.Status -contains 'Fail'
                $entryType = if ($hasFail) { 'Error' } else { 'Information' }
                $payload = @{
                    CorrelationId = $script:correlationId
                    Nodes         = $Nodes
                    Summary       = ($script:results | Group-Object Status | ForEach-Object { @{ $_.Name = $_.Count } })
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
        foreach ($s in $script:nodeSessions.Values) {
            if ($s) { Remove-PSSession -Session $s -ErrorAction SilentlyContinue }
        }
        if ($transcriptStarted) {
            Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
        }
    }

    # Single pipeline output: a structured result object the caller can act on.
    $summary = @{}
    foreach ($g in ($script:results | Group-Object Status)) {
        $summary[$g.Name] = $g.Count
    }

    [pscustomobject]@{
        CorrelationId = $script:correlationId
        Results       = $script:results.ToArray()
        HasFail       = ($script:results.Status -contains 'Fail')
        Summary       = $summary
        Reports       = [pscustomobject]@{
            Json       = $jsonReport
            Html       = $htmlReport
            Transcript = $transcriptPath
        }
    }
}
