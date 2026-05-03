function Get-ClvHostColocation {
    # Pure logic. Given an array of {Name, VMHost.Name} VM-like objects,
    # produce a colocation report: which ESXi hosts hold which VMs, and
    # which hosts hold more than one of our cluster VMs (the
    # anti-affinity violation).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]]$VMs
    )

    $hostMap = @{}
    foreach ($vm in $VMs) {
        $hostName = $vm.VMHost.Name
        if (-not $hostMap.ContainsKey($hostName)) {
            $hostMap[$hostName] = New-Object System.Collections.Generic.List[string]
        }
        [void]$hostMap[$hostName].Add($vm.Name)
    }

    $colocated = foreach ($kv in $hostMap.GetEnumerator()) {
        if ($kv.Value.Count -gt 1) {
            [pscustomobject]@{
                Host = $kv.Key
                VMs  = @($kv.Value)
            }
        }
    }

    [pscustomobject]@{
        HostMap   = $hostMap
        Colocated = @($colocated)
        IsHealthy = (@($colocated).Count -eq 0)
    }
}
