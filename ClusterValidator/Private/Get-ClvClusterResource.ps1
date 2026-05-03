function Get-ClvClusterResource {
    # Single mock point for Get-ClusterResource per Rules §5. Runs the
    # cmdlet on a remote cluster member so we don't need FailoverClusters
    # imported on the orchestrating host.
    [CmdletBinding()]
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
