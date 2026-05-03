function Get-ClvHotFixDrift {
    # Pure logic. Given an array of {ComputerName, HotFixIDs [string[]]},
    # returns the union KB count and a per-node Missing report.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]]$Reports
    )
    $allKbs = $Reports.HotFixIDs | Sort-Object -Unique
    $drift = foreach ($r in $Reports) {
        $missing = @($allKbs | Where-Object { $_ -notin $r.HotFixIDs })
        if ($missing.Count -gt 0) {
            [pscustomobject]@{ ComputerName = $r.ComputerName; Missing = $missing }
        }
    }
    [pscustomobject]@{
        AllKbCount = @($allKbs).Count
        Drift      = @($drift)
    }
}
