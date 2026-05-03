function Get-ClvClusterResource {
    # Single mock point for Get-ClusterResource per Rules §5. Runs the
    # cmdlet on a remote cluster member so we don't need FailoverClusters
    # imported on the orchestrating host.
    #
    # -Session is typed [object] (rather than [PSSession]) for the same
    # testability reason as Invoke-ClvRemote: integration tests pass
    # stub session objects.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $Session
    )
    Invoke-ClvRemote -Session $Session -ScriptBlock {
        Import-Module FailoverClusters -ErrorAction Stop
        Get-ClusterResource |
            Where-Object ResourceType -in 'Physical Disk', 'Cluster Shared Volume' |
            Select-Object Name, OwnerNode, State, ResourceType
    }
}
