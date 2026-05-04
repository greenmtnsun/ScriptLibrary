@{
    RootModule        = 'ClusterValidator.psm1'
    ModuleVersion     = '1.5.0'
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
            ReleaseNotes = '1.5.0 - Splunk integration artifacts under splunk\: Universal Forwarder inputs (Event Log + JSON file paths), props/transforms parsing, named eventtypes, three saved-search alerts (general failures, quorum-class critical, hotfix drift), and a Simple XML dashboard with KPIs / failures-by-phase / failures-by-category / recent-runs drill-down. Module surface unchanged from 1.4.0; this is operational integration glue, not module code.'
        }
    }
}
