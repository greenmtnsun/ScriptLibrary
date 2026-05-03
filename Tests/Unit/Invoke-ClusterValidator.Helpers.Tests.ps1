[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot
)

# Unit suite for the pure-logic helpers inside the ClusterValidator
# module. We use InModuleScope so the test reaches into the module's
# private function table directly - no AST extraction, no live cluster.

BeforeDiscovery {
    $manifest = Join-Path $ProjectRoot 'ClusterValidator\ClusterValidator.psd1'
    Import-Module -Name $manifest -Force -ErrorAction Stop
}

Describe 'ClusterValidator helpers - Unit' {

    Context 'Get-ClvTimeSkew' {
        It 'returns 0 skew when all samples are equal' {
            InModuleScope ClusterValidator {
                $now = [datetime]::UtcNow
                $samples = @(
                    [pscustomobject]@{ ComputerName = 'A'; UtcNow = $now },
                    [pscustomobject]@{ ComputerName = 'B'; UtcNow = $now }
                )
                $r = Get-ClvTimeSkew -Samples $samples
                $r.Skew        | Should -Be 0
                $r.SampleCount | Should -Be 2
            }
        }

        It 'computes the spread between min and max in seconds' {
            InModuleScope ClusterValidator {
                $base = [datetime]::UtcNow
                $samples = @(
                    [pscustomobject]@{ ComputerName = 'A'; UtcNow = $base },
                    [pscustomobject]@{ ComputerName = 'B'; UtcNow = $base.AddSeconds(5) },
                    [pscustomobject]@{ ComputerName = 'C'; UtcNow = $base.AddSeconds(2) }
                )
                $r = Get-ClvTimeSkew -Samples $samples
                $r.Skew | Should -Be 5.0
            }
        }

        It 'returns null skew with fewer than 2 valid samples' {
            InModuleScope ClusterValidator {
                $r = Get-ClvTimeSkew -Samples @(
                    [pscustomobject]@{ ComputerName = 'A'; UtcNow = [datetime]::UtcNow }
                )
                $r.Skew        | Should -BeNullOrEmpty
                $r.SampleCount | Should -Be 1
            }
        }

        It 'ignores samples whose UtcNow is null' {
            InModuleScope ClusterValidator {
                $samples = @(
                    [pscustomobject]@{ ComputerName = 'A'; UtcNow = $null },
                    [pscustomobject]@{ ComputerName = 'B'; UtcNow = [datetime]::UtcNow }
                )
                $r = Get-ClvTimeSkew -Samples $samples
                $r.SampleCount | Should -Be 1
                $r.Skew        | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Get-ClvHotFixDrift' {
        It 'reports no drift when every node has the same KB set' {
            InModuleScope ClusterValidator {
                $reports = @(
                    [pscustomobject]@{ ComputerName = 'A'; HotFixIDs = @('KB1','KB2','KB3') },
                    [pscustomobject]@{ ComputerName = 'B'; HotFixIDs = @('KB1','KB2','KB3') }
                )
                $r = Get-ClvHotFixDrift -Reports $reports
                $r.AllKbCount     | Should -Be 3
                @($r.Drift).Count | Should -Be 0
            }
        }

        It 'flags a node missing a KB the others have' {
            InModuleScope ClusterValidator {
                $reports = @(
                    [pscustomobject]@{ ComputerName = 'A'; HotFixIDs = @('KB1','KB2','KB3') },
                    [pscustomobject]@{ ComputerName = 'B'; HotFixIDs = @('KB1','KB2') }
                )
                $r = Get-ClvHotFixDrift -Reports $reports
                @($r.Drift).Count        | Should -Be 1
                $r.Drift[0].ComputerName | Should -Be 'B'
                $r.Drift[0].Missing      | Should -Be @('KB3')
            }
        }

        It 'flags multiple nodes missing different KBs' {
            InModuleScope ClusterValidator {
                $reports = @(
                    [pscustomobject]@{ ComputerName = 'A'; HotFixIDs = @('KB1','KB2') },
                    [pscustomobject]@{ ComputerName = 'B'; HotFixIDs = @('KB2','KB3') }
                )
                $r = Get-ClvHotFixDrift -Reports $reports
                $r.AllKbCount     | Should -Be 3
                @($r.Drift).Count | Should -Be 2
            }
        }
    }

    Context 'Get-ClvServiceAccountIssues' {
        It 'returns empty when accounts are uniform and non-builtin' {
            InModuleScope ClusterValidator {
                $reports = @(
                    [pscustomobject]@{ ComputerName = 'A'; Services = @(
                        [pscustomobject]@{ Name = 'ClusSvc'; StartName = 'DOMAIN\cluster'; State = 'Running' }
                    )},
                    [pscustomobject]@{ ComputerName = 'B'; Services = @(
                        [pscustomobject]@{ Name = 'ClusSvc'; StartName = 'DOMAIN\cluster'; State = 'Running' }
                    )}
                )
                $issues = Get-ClvServiceAccountIssues -Reports $reports
                @($issues).Count | Should -Be 0
            }
        }

        It 'flags built-in accounts (LocalSystem, etc.)' {
            InModuleScope ClusterValidator {
                $reports = @(
                    [pscustomobject]@{ ComputerName = 'A'; Services = @(
                        [pscustomobject]@{ Name = 'ClusSvc'; StartName = 'LocalSystem'; State = 'Running' }
                    )}
                )
                $issues = Get-ClvServiceAccountIssues -Reports $reports
                @($issues).Count        | Should -Be 1
                $issues[0].Issue        | Should -Be 'BuiltInAccount'
                $issues[0].StartName    | Should -Be 'LocalSystem'
                $issues[0].ComputerName | Should -Be 'A'
            }
        }

        It 'flags account mismatches across nodes for the same service' {
            InModuleScope ClusterValidator {
                $reports = @(
                    [pscustomobject]@{ ComputerName = 'A'; Services = @(
                        [pscustomobject]@{ Name = 'MSSQL$INST'; StartName = 'DOMAIN\sql_a'; State = 'Running' }
                    )},
                    [pscustomobject]@{ ComputerName = 'B'; Services = @(
                        [pscustomobject]@{ Name = 'MSSQL$INST'; StartName = 'DOMAIN\sql_b'; State = 'Running' }
                    )}
                )
                $issues = Get-ClvServiceAccountIssues -Reports $reports
                $mismatch = @($issues | Where-Object Issue -eq 'AccountMismatch')
                $mismatch.Count       | Should -Be 1
                $mismatch[0].Service  | Should -Be 'MSSQL$INST'
            }
        }

        It 'honors a custom -BuiltInAccounts list' {
            InModuleScope ClusterValidator {
                $reports = @(
                    [pscustomobject]@{ ComputerName = 'A'; Services = @(
                        [pscustomobject]@{ Name = 'ClusSvc'; StartName = 'DOMAIN\cluster'; State = 'Running' }
                    )}
                )
                $issues = Get-ClvServiceAccountIssues -Reports $reports `
                                                      -BuiltInAccounts @('DOMAIN\cluster')
                @($issues).Count | Should -Be 1
                $issues[0].Issue | Should -Be 'BuiltInAccount'
            }
        }
    }
}

Describe 'Get-ClvHostColocation (1.2.0)' {

    It 'reports IsHealthy when every VM is on a distinct host' {
        InModuleScope ClusterValidator {
            $vms = @(
                [pscustomobject]@{ Name='sql01'; VMHost=[pscustomobject]@{Name='esx-a'} },
                [pscustomobject]@{ Name='sql02'; VMHost=[pscustomobject]@{Name='esx-b'} },
                [pscustomobject]@{ Name='sql03'; VMHost=[pscustomobject]@{Name='esx-c'} },
                [pscustomobject]@{ Name='sql04'; VMHost=[pscustomobject]@{Name='esx-d'} }
            )
            $r = Get-ClvHostColocation -VMs $vms
            $r.IsHealthy        | Should -BeTrue
            @($r.Colocated).Count | Should -Be 0
            $r.HostMap.Count    | Should -Be 4
        }
    }

    It 'flags the host(s) that hold more than one VM' {
        InModuleScope ClusterValidator {
            $vms = @(
                [pscustomobject]@{ Name='sql01'; VMHost=[pscustomobject]@{Name='esx-a'} },
                [pscustomobject]@{ Name='sql02'; VMHost=[pscustomobject]@{Name='esx-a'} },  # colocated
                [pscustomobject]@{ Name='sql03'; VMHost=[pscustomobject]@{Name='esx-b'} },
                [pscustomobject]@{ Name='sql04'; VMHost=[pscustomobject]@{Name='esx-c'} }
            )
            $r = Get-ClvHostColocation -VMs $vms
            $r.IsHealthy            | Should -BeFalse
            @($r.Colocated).Count   | Should -Be 1
            $r.Colocated[0].Host    | Should -Be 'esx-a'
            @($r.Colocated[0].VMs)  | Should -Be @('sql01','sql02')
        }
    }

    It 'flags multiple colocated host pairs independently' {
        InModuleScope ClusterValidator {
            $vms = @(
                [pscustomobject]@{ Name='sql01'; VMHost=[pscustomobject]@{Name='esx-a'} },
                [pscustomobject]@{ Name='sql02'; VMHost=[pscustomobject]@{Name='esx-a'} },
                [pscustomobject]@{ Name='sql03'; VMHost=[pscustomobject]@{Name='esx-b'} },
                [pscustomobject]@{ Name='sql04'; VMHost=[pscustomobject]@{Name='esx-b'} }
            )
            $r = Get-ClvHostColocation -VMs $vms
            $r.IsHealthy          | Should -BeFalse
            @($r.Colocated).Count | Should -Be 2
        }
    }

    It 'handles a degenerate single-VM input cleanly' {
        InModuleScope ClusterValidator {
            $vms = @(
                [pscustomobject]@{ Name='sql01'; VMHost=[pscustomobject]@{Name='esx-a'} }
            )
            $r = Get-ClvHostColocation -VMs $vms
            $r.IsHealthy        | Should -BeTrue
            $r.HostMap.Count    | Should -Be 1
        }
    }
}

Describe 'Add-ClvResult - Category enforcement (Rules §7, 1.1.0)' {

    BeforeEach {
        # Reset the module's accumulator before each test so assertions
        # don't leak state across cases.
        InModuleScope ClusterValidator {
            $script:correlationId = [guid]::NewGuid().ToString()
            $script:results       = [System.Collections.Generic.List[object]]::new()
        }
    }

    It 'accepts a Pass record without -Category' {
        InModuleScope ClusterValidator {
            { Add-ClvResult -Phase 'Test' -Status 'Pass' -Message 'ok' } | Should -Not -Throw
            $script:results[0].Category | Should -BeNullOrEmpty
            $script:results[0].Status   | Should -Be 'Pass'
        }
    }

    It 'accepts an Info record without -Category' {
        InModuleScope ClusterValidator {
            { Add-ClvResult -Phase 'Test' -Status 'Info' -Message 'fyi' } | Should -Not -Throw
        }
    }

    It 'throws when Status=Fail and -Category is omitted' {
        InModuleScope ClusterValidator {
            { Add-ClvResult -Phase 'Test' -Status 'Fail' -Message 'bad' } |
                Should -Throw -ExpectedMessage '*requires -Category*'
        }
    }

    It 'throws when Status=Warn and -Category is omitted' {
        InModuleScope ClusterValidator {
            { Add-ClvResult -Phase 'Test' -Status 'Warn' -Message 'meh' } |
                Should -Throw -ExpectedMessage '*requires -Category*'
        }
    }

    It 'rejects an unknown -Category via [ValidateSet]' {
        InModuleScope ClusterValidator {
            { Add-ClvResult -Phase 'Test' -Status 'Fail' -Category 'MadeUpCategory' -Message 'x' } |
                Should -Throw
        }
    }

    It 'records the Category column on a successful Fail call' {
        InModuleScope ClusterValidator {
            Add-ClvResult -Phase 'Storage' -Status 'Fail' `
                          -Category 'StorageInventoryError' `
                          -Message 'x'
            $script:results[0].Category | Should -Be 'StorageInventoryError'
        }
    }
}

Describe 'ClusterValidator module - Loader' {
    It 'exports exactly Invoke-ClusterValidator' {
        $exports = (Get-Module ClusterValidator).ExportedFunctions.Keys
        $exports | Should -Be @('Invoke-ClusterValidator')
    }
    It 'is idempotent under repeated Import-Module -Force' {
        $manifest = Join-Path $ProjectRoot 'ClusterValidator\ClusterValidator.psd1'
        { Import-Module -Name $manifest -Force -ErrorAction Stop } | Should -Not -Throw
        (Get-Module ClusterValidator).ExportedFunctions.Keys.Count | Should -Be 1
    }
}
