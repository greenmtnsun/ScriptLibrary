function Invoke-ClvTestCluster {
    # Single mock point for Microsoft Test-Cluster per Rules §5.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]]$Node,
        [string[]]$Include,
        [string[]]$Exclude,
        [Parameter(Mandatory)] [string]$ReportName
    )
    Test-Cluster -Node $Node -Include $Include -Exclude $Exclude -ReportName $ReportName -ErrorAction Stop
}
