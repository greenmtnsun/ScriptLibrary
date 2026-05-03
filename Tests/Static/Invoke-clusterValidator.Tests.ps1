[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot
)

# Static test suite for Invoke-clusterValidator.ps1.
# Enforces ClusterValidator-Rules.md §2-§7 against the source on disk
# without requiring a live cluster, dbatools, or any remote endpoint.

Describe 'Invoke-clusterValidator.ps1 - Static' {

    BeforeAll {
        $script:OrchestratorPath = Join-Path $ProjectRoot 'Invoke-clusterValidator.ps1'
        $script:OrchestratorText = Get-Content -Path $script:OrchestratorPath -Raw

        $tokens = $null
        $errors = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:OrchestratorPath, [ref]$tokens, [ref]$errors)
        $script:ParseErrors = $errors
    }

    It 'orchestrator file exists' {
        Test-Path -Path $script:OrchestratorPath -PathType Leaf | Should -BeTrue
    }

    It 'parses without errors' {
        $script:ParseErrors | Should -BeNullOrEmpty
    }

    It 'declares the required #Requires statements' {
        $script:OrchestratorText | Should -Match '#Requires\s+-Version\s+5\.1'
        $script:OrchestratorText | Should -Match '#Requires\s+-RunAsAdministrator'
        $script:OrchestratorText | Should -Match '#Requires\s+-Modules\s+FailoverClusters'
    }

    It 'uses [CmdletBinding()]' {
        $script:OrchestratorText | Should -Match '\[CmdletBinding\(\)\]'
    }

    It 'declares Nodes as a mandatory parameter' {
        $nodesParam = $script:Ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'Nodes' }
        $nodesParam | Should -Not -BeNullOrEmpty

        $mandatoryArg = $nodesParam.Attributes |
            Where-Object { $_.TypeName.Name -eq 'Parameter' } |
            ForEach-Object { $_.NamedArguments } |
            Where-Object { $_.ArgumentName -eq 'Mandatory' }
        $mandatoryArg | Should -Not -BeNullOrEmpty
    }

    Context 'Rules §2 - no $PSScriptRoot anywhere in the project' {
        It 'contains no $PSScriptRoot variable reference in any .ps1 in the tree' {
            # AST-based scan: only flags real variable references, not regex
            # literals or comments (where the token is legitimately mentioned).
            $offenders = Get-ChildItem -Path $ProjectRoot -Filter '*.ps1' -Recurse -File | ForEach-Object {
                $t = $null; $e = $null
                $fileAst = [System.Management.Automation.Language.Parser]::ParseFile(
                    $_.FullName, [ref]$t, [ref]$e)
                $hit = $fileAst.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.VariablePath.UserPath -eq 'PSScriptRoot'
                }, $true)
                if ($hit) { $_.FullName }
            }
            $offenders | Should -BeNullOrEmpty -Because 'ClusterValidator-Rules.md §2 forbids $PSScriptRoot'
        }
    }

    Context 'Rules §4 - orchestrator phase contract (in order)' {
        It 'declares all 13 phase markers in monotonically increasing order' {
            $expected = @(
                '# Phase 1: PreFlight',
                '# Phase 2: MPIO',
                '# Phase 3: Storage',
                '# Phase 4: SCSI3',
                '# Phase 5: Quorum',
                '# Phase 6: Heartbeat',
                '# Phase 7: Time',
                '# Phase 8: Reboot',
                '# Phase 9: Hotfix',
                '# Phase 10: ServiceAccount',
                '# Phase 11: TestCluster',
                '# Phase 12: Forensic',
                '# Phase 13: Persist'
            )
            $previous = -1
            foreach ($marker in $expected) {
                $idx = $script:OrchestratorText.IndexOf($marker)
                $idx | Should -BeGreaterThan $previous -Because "phase marker '$marker' must be present and follow the previous one"
                $previous = $idx
            }
        }
    }

    Context 'Rules §5 - external-cmdlet wrappers exist' {
        It 'defines Invoke-ClvRemote' {
            $script:OrchestratorText | Should -Match 'function\s+Invoke-ClvRemote\b'
        }
        It 'defines Invoke-ClvTestCluster' {
            $script:OrchestratorText | Should -Match 'function\s+Invoke-ClvTestCluster\b'
        }
        It 'defines Get-ClvClusterResource' {
            $script:OrchestratorText | Should -Match 'function\s+Get-ClvClusterResource\b'
        }
        It 'invokes Test-Cluster only via the wrapper' {
            $direct = Select-String -Path $script:OrchestratorPath -Pattern '(?<![-\w])Test-Cluster(?![-\w])' |
                Where-Object { $_.Line -notmatch '(function|Invoke-ClvTestCluster)' }
            $direct | Should -BeNullOrEmpty -Because 'Test-Cluster is wrapped per Rules §5'
        }
    }

    Context 'Rules §6 - read-only discipline (no cluster-mutating cmdlets)' {
        $forbidden = @(
            'Move-ClusterGroup',
            'Move-ClusterSharedVolume',
            'Start-ClusterResource',
            'Stop-ClusterResource',
            'Set-ClusterParameter',
            'Set-ClusterQuorum',
            'Clear-ClusterDiskReservation'
        )
        foreach ($cmd in $forbidden) {
            It "does not invoke forbidden cmdlet: $cmd" {
                $pattern = "(?<![-\w])$([regex]::Escape($cmd))(?![-\w])"
                $script:OrchestratorText | Should -Not -Match $pattern
            }
        }
    }

    Context 'Roadmap Phase 2 - Validation Depth' {
        It 'exposes -ExpectedQuorumType, -TimeSkewToleranceSeconds, -ForensicCaptureMinutes' {
            $paramNames = $script:Ast.ParamBlock.Parameters.Name.VariablePath.UserPath
            $paramNames | Should -Contain 'ExpectedQuorumType'
            $paramNames | Should -Contain 'TimeSkewToleranceSeconds'
            $paramNames | Should -Contain 'ForensicCaptureMinutes'
        }
        It 'invokes Get-ClusterQuorum for the Quorum phase' {
            $script:OrchestratorText | Should -Match '(?<![-\w])Get-ClusterQuorum(?![-\w])'
        }
        It 'invokes Get-Cluster for heartbeat thresholds' {
            $script:OrchestratorText | Should -Match '(?<![-\w])Get-Cluster\b\s*\|'
        }
        It 'invokes Get-HotFix for hotfix parity' {
            $script:OrchestratorText | Should -Match '(?<![-\w])Get-HotFix(?![-\w])'
        }
        It 'invokes Get-CimInstance for service account interrogation' {
            $script:OrchestratorText | Should -Match '(?<![-\w])Get-CimInstance(?![-\w])'
        }
        It 'invokes Get-ClusterLog inside the Forensic phase only on Fail' {
            $script:OrchestratorText | Should -Match '(?<![-\w])Get-ClusterLog(?![-\w])'
            $script:OrchestratorText | Should -Match 'results\.Status\s+-contains\s+''Fail'''
        }
        It 'computes time skew via UTC timestamps' {
            $script:OrchestratorText | Should -Match '\.ToUniversalTime\(\)'
        }
        It 'fans out reads via the multi-session wrapper' {
            $script:OrchestratorText | Should -Match 'Invoke-ClvRemote\s+-Sessions\b'
        }
    }

    Context 'Roadmap Phase 3 - Security Hardening' {
        It 'exposes -Credential, -CredentialSecretName, -HardenReportAcl' {
            $paramNames = $script:Ast.ParamBlock.Parameters.Name.VariablePath.UserPath
            $paramNames | Should -Contain 'Credential'
            $paramNames | Should -Contain 'CredentialSecretName'
            $paramNames | Should -Contain 'HardenReportAcl'
        }
        It 'enforces FullLanguage mode preflight before transcript opens' {
            $script:OrchestratorText | Should -Match 'LanguageMode\s+-ne\s+''FullLanguage'''
            $clmIdx       = $script:OrchestratorText.IndexOf('LanguageMode')
            $transcriptIdx = $script:OrchestratorText.IndexOf('Start-Transcript')
            $clmIdx | Should -BeLessThan $transcriptIdx -Because 'CLM preflight must run before Start-Transcript'
        }
        It 'resolves credentials via Microsoft.PowerShell.SecretManagement' {
            $script:OrchestratorText | Should -Match 'Microsoft\.PowerShell\.SecretManagement'
            $script:OrchestratorText | Should -Match '(?<![-\w])Get-Secret(?![-\w])'
        }
        It 'passes the resolved credential to New-PSSession' {
            $script:OrchestratorText | Should -Match 'sessionParams\.Credential\s*=\s*\$Credential'
        }
        It 'hardens the report directory DACL on demand' {
            $script:OrchestratorText | Should -Match 'SetAccessRuleProtection'
            $script:OrchestratorText | Should -Match 'NT AUTHORITY\\SYSTEM'
            $script:OrchestratorText | Should -Match 'BUILTIN\\Administrators'
            # Hardening must run before transcript so the file inherits the DACL.
            $aclIdx        = $script:OrchestratorText.IndexOf('SetAccessRuleProtection')
            $transcriptIdx = $script:OrchestratorText.IndexOf('Start-Transcript')
            $aclIdx | Should -BeLessThan $transcriptIdx
        }
        It 'documents AllSigned and gMSA expectations in .NOTES' {
            $script:OrchestratorText | Should -Match 'AllSigned'
            $script:OrchestratorText | Should -Match '(gMSA|Group Managed Service Account)'
        }
        It 'contains no hardcoded plaintext credentials' {
            $script:OrchestratorText | Should -Not -Match 'ConvertTo-SecureString[^|]+-AsPlainText'
            $script:OrchestratorText | Should -Not -Match '\$pass(word)?\s*=\s*[''"][^''"]+[''"]'
        }
    }

    Context 'Roadmap Phase 1 - Audit & Observability' {
        It 'generates a correlation GUID' {
            $script:OrchestratorText | Should -Match '\[guid\]::NewGuid\(\)'
        }
        It 'starts a transcript' {
            $script:OrchestratorText | Should -Match 'Start-Transcript'
        }
        It 'stops the transcript inside a finally block' {
            $script:OrchestratorText | Should -Match 'Stop-Transcript'
            $script:OrchestratorText | Should -Match 'finally\s*\{'
        }
        It 'uses Test-WSMan for reachability instead of Test-Connection' {
            $script:OrchestratorText | Should -Match '(?<![-\w])Test-WSMan(?![-\w])'
            $script:OrchestratorText | Should -Not -Match '(?<![-\w])Test-Connection(?![-\w])'
        }
        It 'opens reusable PSSessions with explicit timeouts' {
            $script:OrchestratorText | Should -Match 'New-PSSession\b'
            $script:OrchestratorText | Should -Match 'New-PSSessionOption\b'
            $script:OrchestratorText | Should -Match '-OperationTimeout'
            $script:OrchestratorText | Should -Match '-OpenTimeout'
            $script:OrchestratorText | Should -Match 'Remove-PSSession\b'
        }
        It 'stamps every result record with the correlation GUID' {
            $script:OrchestratorText | Should -Match 'CorrelationId\s*=\s*\$correlationId'
        }
    }
}
