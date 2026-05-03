@{
    RootModule        = 'ClusterValidator.psm1'
    ModuleVersion     = '1.4.0'
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

    FunctionsToExport = @(
        'Invoke-ClusterValidator',
        'Test-ClusterValidatorConfig'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Cluster', 'Validation', 'SQL', 'FCI', 'SAN', 'SCSI3', 'MPIO')
            ProjectUri   = 'https://github.com/greenmtnsun/scriptlibrary'
            ReleaseNotes = '1.4.0 - Pester integration suite. Drives Invoke-ClusterValidator end-to-end with every external cmdlet mocked: per-phase Pass and Fail simulations for Storage, Quorum, Heartbeat, Time, Reboot, Hotfix, ServiceAccount, VMware, TestCluster, Forensic, plus a happy-path test asserting all 14 phases produce records and a single correlation GUID stamps the whole run. Closes the Phase 4 acceptance-criteria gap.'
        }
    }
}
