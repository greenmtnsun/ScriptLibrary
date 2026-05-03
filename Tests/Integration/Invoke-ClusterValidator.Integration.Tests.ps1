[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot
)

# Integration suite. Drives Invoke-ClusterValidator end-to-end with
# every external cmdlet mocked, so each phase's success / failure
# branches are exercised without a live cluster, vCenter, MPIO stack,
# or admin token.
#
# Mock discrimination strategy: per-phase Invoke-ClvRemote calls all
# carry distinct ScriptBlock text. We use Pester's -ParameterFilter
# matching against $ScriptBlock.ToString() so each phase gets exactly
# the canned response it needs.

BeforeDiscovery {
    Import-Module (Join-Path $ProjectRoot 'ClusterValidator\ClusterValidator.psd1') -Force
}

Describe 'Invoke-ClusterValidator integration' {

    BeforeEach {
        # TestDrive gives us a real directory the orchestrator can
        # write JSON / transcript artifacts into without polluting the
        # workspace.
        $script:reportDir = Join-Path $TestDrive 'reports'
        $null = New-Item -Path $script:reportDir -ItemType Directory -Force

        InModuleScope ClusterValidator {

            # ----- Universal Pass-path mocks ---------------------------------
            # Anything not overridden by an individual It-block gets these.

            Mock Test-ClvElevation { $true }

            Mock Start-Transcript { } -Verifiable
            Mock Stop-Transcript  { }

            Mock Get-Module -ParameterFilter {
                $ListAvailable -and $Name -in 'FailoverClusters','MPIO'
            } -MockWith {
                [pscustomobject]@{ Name = $Name; ModuleType = 'Manifest' }
            }

            Mock Test-WSMan { [pscustomobject]@{ ProductVendor = 'Microsoft' } }

            Mock New-PSSessionOption { [pscustomobject]@{ StubOption = $true } }

            Mock New-PSSession {
                [pscustomobject]@{
                    ComputerName = $ComputerName
                    Id           = [int](Get-Random -Maximum 9999)
                    StubSession  = $true
                }
            }

            Mock Remove-PSSession { }

            Mock Get-MSDSMGlobalDefaultLoadBalancePolicy { 'RoundRobin' }

            # Phase 3 Storage
            Mock Invoke-ClvRemote -ParameterFilter {
                $ScriptBlock.ToString() -match 'Get-Disk'
            } -MockWith {
                @(
                    [pscustomobject]@{ ComputerName = 'n1'; Count = 32; Serials = 'A,B,C' },
                    [pscustomobject]@{ ComputerName = 'n2'; Count = 32; Serials = 'A,B,C' }
                )
            }

            # Phase 4 SCSI3 (via Get-ClvClusterResource wrapper)
            Mock Get-ClvClusterResource {
                @(
                    [pscustomobject]@{ Name='Cluster Disk 1'; OwnerNode='n1'; State='Online'; ResourceType='Physical Disk' }
                )
            }

            # Phase 5 Quorum
            Mock Invoke-ClvRemote -ParameterFilter {
                $ScriptBlock.ToString() -match 'Get-ClusterQuorum'
            } -MockWith {
                [pscustomobject]@{
                    QuorumType     = 'NodeAndDiskMajority'
                    QuorumResource = 'Cluster Disk Q'
                    ResourceState  = 'Online'
                }
            }

            # Phase 6 Heartbeat
            Mock Invoke-ClvRemote -ParameterFilter {
                $ScriptBlock.ToString() -match 'Get-Cluster\s*\|\s*Select-Object'
            } -MockWith {
                [pscustomobject]@{
                    Name                 = 'TESTCLUSTER'
                    SameSubnetThreshold  = 10
                    SameSubnetDelay      = 1000
                    CrossSubnetThreshold = 20
                    CrossSubnetDelay     = 1000
                    RouteHistoryLength   = 10
                }
            }

            # Phase 7 Time
            Mock Invoke-ClvRemote -ParameterFilter {
                $ScriptBlock.ToString() -match 'ToUniversalTime'
            } -MockWith {
                $now = [datetime]::UtcNow
                @(
                    [pscustomobject]@{ ComputerName='n1'; UtcNow=$now },
                    [pscustomobject]@{ ComputerName='n2'; UtcNow=$now.AddMilliseconds(500) }
                )
            }

            # Phase 8 Reboot
            Mock Invoke-ClvRemote -ParameterFilter {
                $ScriptBlock.ToString() -match 'RebootPending'
            } -MockWith {
                @(
                    [pscustomobject]@{ ComputerName='n1'; Reasons=@() },
                    [pscustomobject]@{ ComputerName='n2'; Reasons=@() }
                )
            }

            # Phase 9 Hotfix
            Mock Invoke-ClvRemote -ParameterFilter {
                $ScriptBlock.ToString() -match 'Get-HotFix'
            } -MockWith {
                @(
                    [pscustomobject]@{ ComputerName='n1'; HotFixIDs=@('KB1','KB2','KB3') },
                    [pscustomobject]@{ ComputerName='n2'; HotFixIDs=@('KB1','KB2','KB3') }
                )
            }

            # Phase 10 ServiceAccount
            Mock Invoke-ClvRemote -ParameterFilter {
                $ScriptBlock.ToString() -match 'Win32_Service'
            } -MockWith {
                @(
                    [pscustomobject]@{
                        ComputerName = 'n1'
                        Services = @(
                            [pscustomobject]@{ Name='ClusSvc'; StartName='DOMAIN\cluster'; State='Running' }
                        )
                    },
                    [pscustomobject]@{
                        ComputerName = 'n2'
                        Services = @(
                            [pscustomobject]@{ Name='ClusSvc'; StartName='DOMAIN\cluster'; State='Running' }
                        )
                    }
                )
            }

            # Phase 12 TestCluster
            Mock Invoke-ClvTestCluster { $true }

            # Phase 13 Forensic (only fires on Fail; harmless to mock always)
            Mock Get-ClusterLog { }
        }
    }

    Context 'Happy path - everything Pass' {

        It 'returns HasFail=$false and 14 phases worth of records' {
            $r = Invoke-ClusterValidator -Nodes 'n1','n2' -ReportPath $script:reportDir
            $r.HasFail | Should -BeFalse

            # Every phase must have at least one record
            $phases = @($r.Results | Select-Object -ExpandProperty Phase -Unique)
            $phases | Should -Contain 'PreFlight'
            $phases | Should -Contain 'MPIO'
            $phases | Should -Contain 'Storage'
            $phases | Should -Contain 'SCSI3'
            $phases | Should -Contain 'Quorum'
            $phases | Should -Contain 'Heartbeat'
            $phases | Should -Contain 'Time'
            $phases | Should -Contain 'Reboot'
            $phases | Should -Contain 'Hotfix'
            $phases | Should -Contain 'ServiceAccount'
            $phases | Should -Contain 'VMware'
            $phases | Should -Contain 'TestCluster'
            $phases | Should -Contain 'Forensic'
        }

        It 'writes the JSON artifact to ReportPath' {
            $null = Invoke-ClusterValidator -Nodes 'n1','n2' -ReportPath $script:reportDir
            $jsonFile = Get-ChildItem -Path $script:reportDir -Filter '*.json' | Select-Object -First 1
            $jsonFile | Should -Not -BeNullOrEmpty
            $jsonFile.Length | Should -BeGreaterThan 0
        }

        It 'stamps every record with the same correlation GUID' {
            $r = Invoke-ClusterValidator -Nodes 'n1','n2' -ReportPath $script:reportDir
            $ids = @($r.Results.CorrelationId | Sort-Object -Unique)
            $ids.Count       | Should -Be 1
            $ids[0]          | Should -Be $r.CorrelationId
            { [guid]::Parse($r.CorrelationId) } | Should -Not -Throw
        }
    }

    Context 'Phase 3 Storage Fail - disk count mismatch' {
        It 'reports Fail with StorageInventoryError when a node sees the wrong count' {
            InModuleScope ClusterValidator {
                Mock Invoke-ClvRemote -ParameterFilter {
                    $ScriptBlock.ToString() -match 'Get-Disk'
                } -MockWith {
                    @(
                        [pscustomobject]@{ ComputerName='n1'; Count=32; Serials='A,B,C' },
                        [pscustomobject]@{ ComputerName='n2'; Count=30; Serials='A,B,C' }  # wrong count
                    )
                }
            }
            $r = Invoke-ClusterValidator -Nodes 'n1','n2' -ReportPath $script:reportDir
            $r.HasFail | Should -BeTrue
            $storageFail = @($r.Results | Where-Object { $_.Phase -eq 'Storage' -and $_.Status -eq 'Fail' })
            $storageFail.Count               | Should -BeGreaterThan 0
            $storageFail[0].Category         | Should -Be 'StorageInventoryError'
        }
    }

    Context 'Phase 3 Storage Fail - LUN serial divergence' {
        It 'reports Fail with StorageTopologyError when serial sets diverge' {
            InModuleScope ClusterValidator {
                Mock Invoke-ClvRemote -ParameterFilter {
                    $ScriptBlock.ToString() -match 'Get-Disk'
                } -MockWith {
                    @(
                        [pscustomobject]@{ ComputerName='n1'; Count=32; Serials='A,B,C' },
                        [pscustomobject]@{ ComputerName='n2'; Count=32; Serials='A,B,D' }  # different
                    )
                }
            }
            $r = Invoke-ClusterValidator -Nodes 'n1','n2' -ReportPath $script:reportDir
            $r.HasFail | Should -BeTrue
            $topology = @($r.Results | Where-Object { $_.Phase -eq 'Storage' -and $_.Category -eq 'StorageTopologyError' })
            $topology.Count | Should -BeGreaterThan 0
        }
    }

    Context 'Phase 5 Quorum Fail - witness offline' {
        It 'reports Fail with QuorumStateError' {
            InModuleScope ClusterValidator {
                Mock Invoke-ClvRemote -ParameterFilter {
                    $ScriptBlock.ToString() -match 'Get-ClusterQuorum'
                } -MockWith {
                    [pscustomobject]@{
                        QuorumType     = 'NodeAndDiskMajority'
                        QuorumResource = 'Cluster Disk Q'
                        ResourceState  = 'Failed'
                    }
                }
            }
            $r = Invoke-ClusterValidator -Nodes 'n1','n2' -ReportPath $script:reportDir
            $r.HasFail | Should -BeTrue
            $q = @($r.Results | Where-Object { $_.Phase -eq 'Quorum' -and $_.Status -eq 'Fail' })
            $q.Count       | Should -BeGreaterThan 0
            $q[0].Category | Should -Be 'QuorumStateError'
        }

        It 'reports Fail when -ExpectedQuorumType does not match' {
            $r = Invoke-ClusterValidator -Nodes 'n1','n2' -ReportPath $script:reportDir `
                                          -ExpectedQuorumType 'NodeMajority'
            $r.HasFail | Should -BeTrue
            $q = @($r.Results | Where-Object { $_.Phase -eq 'Quorum' -and $_.Status -eq 'Fail' })
            $q[0].Category | Should -Be 'QuorumStateError'
        }
    }

    Context 'Phase 6 Heartbeat Warn - thresholds below default' {
        It 'reports Warn with ClusterHeartbeatError when SameSubnetThreshold < 10' {
            InModuleScope ClusterValidator {
                Mock Invoke-ClvRemote -ParameterFilter {
                    $ScriptBlock.ToString() -match 'Get-Cluster\s*\|\s*Select-Object'
                } -MockWith {
                    [pscustomobject]@{
                        Name                 = 'TESTCLUSTER'
                        SameSubnetThreshold  = 5    # below default
                        SameSubnetDelay      = 1000
                        CrossSubnetThreshold = 20
                        CrossSubnetDelay     = 1000
                        RouteHistoryLength   = 10
                    }
                }
            }
            $r = Invoke-ClusterValidator -Nodes 'n1','n2' -ReportPath $script:reportDir
            $hb = @($r.Results | Where-Object { $_.Phase -eq 'Heartbeat' -and $_.Status -eq 'Warn' })
            $hb.Count       | Should -BeGreaterThan 0
            $hb[0].Category | Should -Be 'ClusterHeartbeatError'
        }
    }

    Context 'Phase 7 Time Fail - skew exceeds tolerance' {
        It 'reports Fail with TimeSkewError when nodes diverge beyond tolerance' {
            InModuleScope ClusterValidator {
                Mock Invoke-ClvRemote -ParameterFilter {
                    $ScriptBlock.ToString() -match 'ToUniversalTime'
                } -MockWith {
                    $now = [datetime]::UtcNow
                    @(
                        [pscustomobject]@{ ComputerName='n1'; UtcNow=$now },
                        [pscustomobject]@{ ComputerName='n2'; UtcNow=$now.AddSeconds(10) }  # 10s skew
                    )
                }
            }
            $r = Invoke-ClusterValidator -Nodes 'n1','n2' -ReportPath $script:reportDir `
                                          -TimeSkewToleranceSeconds 2
            $r.HasFail | Should -BeTrue
            $t = @($r.Results | Where-Object { $_.Phase -eq 'Time' -and $_.Status -eq 'Fail' })
            $t.Count       | Should -BeGreaterThan 0
            $t[0].Category | Should -Be 'TimeSkewError'
        }
    }

    Context 'Phase 8 Reboot Fail - pending reboot detected' {
        It 'reports Fail with PendingRebootDetected for the offending node' {
            InModuleScope ClusterValidator {
                Mock Invoke-ClvRemote -ParameterFilter {
                    $ScriptBlock.ToString() -match 'RebootPending'
                } -MockWith {
                    @(
                        [pscustomobject]@{ ComputerName='n1'; Reasons=@() },
                        [pscustomobject]@{ ComputerName='n2'; Reasons=@('CBS','WindowsUpdate') }
                    )
                }
            }
            $r = Invoke-ClusterValidator -Nodes 'n1','n2' -ReportPath $script:reportDir
            $r.HasFail | Should -BeTrue
            $rb = @($r.Results | Where-Object { $_.Phase -eq 'Reboot' -and $_.Status -eq 'Fail' })
            $rb.Count       | Should -Be 1
            $rb[0].Category | Should -Be 'PendingRebootDetected'
        }
    }

    Context 'Phase 9 Hotfix Warn - drift detected' {
        It 'reports Warn with HotfixParityError' {
            InModuleScope ClusterValidator {
                Mock Invoke-ClvRemote -ParameterFilter {
                    $ScriptBlock.ToString() -match 'Get-HotFix'
                } -MockWith {
                    @(
                        [pscustomobject]@{ ComputerName='n1'; HotFixIDs=@('KB1','KB2','KB3') },
                        [pscustomobject]@{ ComputerName='n2'; HotFixIDs=@('KB1','KB2') }
                    )
                }
            }
            $r = Invoke-ClusterValidator -Nodes 'n1','n2' -ReportPath $script:reportDir
            $hf = @($r.Results | Where-Object { $_.Phase -eq 'Hotfix' -and $_.Status -eq 'Warn' })
            $hf.Count       | Should -BeGreaterThan 0
            $hf[0].Category | Should -Be 'HotfixParityError'
        }
    }

    Context 'Phase 10 ServiceAccount Warn - built-in account' {
        It 'reports Warn with ServiceAccountError' {
            InModuleScope ClusterValidator {
                Mock Invoke-ClvRemote -ParameterFilter {
                    $ScriptBlock.ToString() -match 'Win32_Service'
                } -MockWith {
                    @(
                        [pscustomobject]@{
                            ComputerName='n1'
                            Services=@([pscustomobject]@{ Name='ClusSvc'; StartName='LocalSystem'; State='Running' })
                        }
                    )
                }
            }
            $r = Invoke-ClusterValidator -Nodes 'n1','n2' -ReportPath $script:reportDir
            $sa = @($r.Results | Where-Object { $_.Phase -eq 'ServiceAccount' -and $_.Status -eq 'Warn' })
            $sa.Count       | Should -BeGreaterThan 0
            $sa[0].Category | Should -Be 'ServiceAccountError'
        }
    }

    Context 'Phase 11 VMware - skipped without -VCenterServer' {
        It 'records an Info skip message when VCenterServer is not supplied' {
            $r = Invoke-ClusterValidator -Nodes 'n1','n2' -ReportPath $script:reportDir
            $vm = @($r.Results | Where-Object Phase -eq 'VMware')
            $vm.Count    | Should -BeGreaterOrEqual 1
            $vm[0].Status | Should -Be 'Info'
            $vm[0].Message | Should -Match 'not provided'
        }
    }

    Context 'Phase 12 TestCluster Fail' {
        It 'reports Fail with TestClusterFailure when Invoke-ClvTestCluster throws' {
            InModuleScope ClusterValidator {
                Mock Invoke-ClvTestCluster { throw 'simulated test-cluster failure' }
            }
            $r = Invoke-ClusterValidator -Nodes 'n1','n2' -ReportPath $script:reportDir
            $r.HasFail | Should -BeTrue
            $tc = @($r.Results | Where-Object { $_.Phase -eq 'TestCluster' -and $_.Status -eq 'Fail' })
            $tc[0].Category | Should -Be 'TestClusterFailure'
        }
    }

    Context 'Phase 13 Forensic - fires only on Fail' {
        It 'emits a Forensic Info "skipped" record on a clean run' {
            $r = Invoke-ClusterValidator -Nodes 'n1','n2' -ReportPath $script:reportDir
            $f = @($r.Results | Where-Object { $_.Phase -eq 'Forensic' })
            $f[0].Status | Should -Be 'Info'
            $f[0].Message | Should -Match 'skipped'
        }

        It 'invokes Get-ClusterLog when a prior phase recorded Fail' {
            InModuleScope ClusterValidator {
                Mock Invoke-ClvTestCluster { throw 'force a fail' }
            }
            $null = Invoke-ClusterValidator -Nodes 'n1','n2' -ReportPath $script:reportDir
            InModuleScope ClusterValidator {
                Should -Invoke Get-ClusterLog -Times 1 -Exactly
            }
        }
    }

    Context 'PreFlight Fail - WSMan unreachable on every node' {
        It 'aborts before any phase 2+ work fires' {
            InModuleScope ClusterValidator {
                Mock Test-WSMan { throw 'unreachable' }
            }
            { Invoke-ClusterValidator -Nodes 'n1','n2' -ReportPath $script:reportDir } |
                Should -Throw -ExpectedMessage '*Fewer than two nodes reachable*'
        }
    }
}
