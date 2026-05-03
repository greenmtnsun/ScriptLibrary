@{
    RootModule        = 'ClusterValidator.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b836e54f-ed7b-48a0-b3ce-fa369678f13d'
    Author            = 'ScriptLibrary maintainers'
    CompanyName       = 'GreenMtnSun'
    Copyright         = '(c) GreenMtnSun. All rights reserved.'
    Description       = 'Targeted validation for Windows Server failover clusters hosting SQL Server FCI workloads on traditional SAN/VMware topologies. Non-destructive: storage, MPIO, SCSI-3 reservation, quorum, heartbeat, time, reboot, hotfix parity, service-account hygiene, plus the official Microsoft Test-Cluster suite.'

    PowerShellVersion = '5.1'

    # FailoverClusters ships with the RSAT Failover Clustering feature on
    # Windows Server. The module is a hard dependency; MPIO is a soft
    # dependency checked at runtime by Phase 1 PreFlight.
    RequiredModules   = @('FailoverClusters')

    FunctionsToExport = @('Invoke-ClusterValidator')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Cluster', 'Validation', 'SQL', 'FCI', 'SAN', 'SCSI3', 'MPIO')
            ProjectUri   = 'https://github.com/greenmtnsun/scriptlibrary'
            ReleaseNotes = 'Initial module release. Feature parity with the prior single-script form (roadmap phases 1-4 complete: audit/observability, validation depth, security hardening, scale and config-driven runs).'
        }
    }
}
