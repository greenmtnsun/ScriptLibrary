function Get-ClvServiceAccountIssues {
    # Pure logic. Given an array of {ComputerName, Services [{Name,
    # StartName, State}]}, returns issue records flagging built-in
    # accounts and cross-node account mismatches.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]]$Reports,

        [string[]]$BuiltInAccounts = @(
            'LocalSystem',
            'NT AUTHORITY\LocalService',
            'NT AUTHORITY\NetworkService'
        )
    )

    $issues = New-Object System.Collections.Generic.List[object]

    foreach ($r in $Reports) {
        foreach ($svc in $r.Services) {
            if ($svc.StartName -in $BuiltInAccounts) {
                $issues.Add([pscustomobject]@{
                    ComputerName = $r.ComputerName
                    Service      = $svc.Name
                    StartName    = $svc.StartName
                    Issue        = 'BuiltInAccount'
                })
            }
        }
    }

    $serviceMap = @{}
    foreach ($r in $Reports) {
        foreach ($svc in $r.Services) {
            if (-not $serviceMap.ContainsKey($svc.Name)) {
                $serviceMap[$svc.Name] = @{}
            }
            $serviceMap[$svc.Name][$r.ComputerName] = $svc.StartName
        }
    }
    foreach ($svcName in $serviceMap.Keys) {
        $accounts = @($serviceMap[$svcName].Values | Sort-Object -Unique)
        if ($accounts.Count -gt 1) {
            $issues.Add([pscustomobject]@{
                Service  = $svcName
                Accounts = $serviceMap[$svcName]
                Issue    = 'AccountMismatch'
            })
        }
    }

    , $issues.ToArray()
}
