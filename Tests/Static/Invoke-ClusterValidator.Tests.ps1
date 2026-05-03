[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot
)

# Static test suite. Validates the on-disk shape of the
# ClusterValidator module without importing it (no live cluster, no
# Pester mocks needed).

Describe 'ClusterValidator module - Static' {

    BeforeAll {
        $script:ModuleRoot       = Join-Path $ProjectRoot 'ClusterValidator'
        $script:ManifestPath     = Join-Path $script:ModuleRoot 'ClusterValidator.psd1'
        $script:LoaderPath       = Join-Path $script:ModuleRoot 'ClusterValidator.psm1'
        $script:OrchestratorPath = Join-Path $script:ModuleRoot 'Public\Invoke-ClusterValidator.ps1'
        $script:WrapperPath      = Join-Path $ProjectRoot 'Invoke-clusterValidator.ps1'

        $script:OrchestratorText = Get-Content -Path $script:OrchestratorPath -Raw

        $tokens = $null; $errors = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:OrchestratorPath, [ref]$tokens, [ref]$errors)
        $script:ParseErrors = $errors

        # Function AST inside the public file (one definition: Invoke-ClusterValidator)
        $script:FunctionAst = $script:Ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true) | Where-Object Name -eq 'Invoke-ClusterValidator' | Select-Object -First 1
    }

    It 'public file parses without errors' {
        $script:ParseErrors | Should -BeNullOrEmpty
    }

    It 'defines Invoke-ClusterValidator as a function' {
        $script:FunctionAst | Should -Not -BeNullOrEmpty
    }

    It 'declares [CmdletBinding()] on the public function' {
        $script:OrchestratorText | Should -Match '\[CmdletBinding\(\)\]'
    }

    It 'declares Nodes as a mandatory parameter' {
        $nodesParam = $script:FunctionAst.Body.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'Nodes' }
        $nodesParam | Should -Not -BeNullOrEmpty

        $mandatoryArg = $nodesParam.Attributes |
            Where-Object { $_.TypeName.Name -eq 'Parameter' } |
            ForEach-Object { $_.NamedArguments } |
            Where-Object { $_.ArgumentName -eq 'Mandatory' }
        $mandatoryArg | Should -Not -BeNullOrEmpty
    }

    Context 'Rules §2 - $PSScriptRoot only allowed in module loader' {
        It 'no .ps1 file uses $PSScriptRoot as a variable reference' {
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
            $offenders | Should -BeNullOrEmpty -Because 'Rules §2 forbids $PSScriptRoot in .ps1 files (carve-out is .psm1 only)'
        }
    }

    Context 'Rules §4 - orchestrator phase contract' {
        It 'public function declares all 14 phase markers in order' {
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
                '# Phase 11: VMware',
                '# Phase 12: TestCluster',
                '# Phase 13: Forensic',
                '# Phase 14: Persist'
            )
            $previous = -1
            foreach ($marker in $expected) {
                $idx = $script:OrchestratorText.IndexOf($marker)
                $idx | Should -BeGreaterThan $previous -Because "phase marker '$marker' must be present and follow the previous one"
                $previous = $idx
            }
        }
    }

    Context 'Rules §5 - external-cmdlet wrappers exist as private helpers' {
        It 'Private/Invoke-ClvRemote.ps1 defines Invoke-ClvRemote' {
            $path = Join-Path $script:ModuleRoot 'Private\Invoke-ClvRemote.ps1'
            (Get-Content $path -Raw) | Should -Match 'function\s+Invoke-ClvRemote\b'
        }
        It 'Private/Invoke-ClvTestCluster.ps1 defines Invoke-ClvTestCluster' {
            $path = Join-Path $script:ModuleRoot 'Private\Invoke-ClvTestCluster.ps1'
            (Get-Content $path -Raw) | Should -Match 'function\s+Invoke-ClvTestCluster\b'
        }
        It 'Private/Get-ClvClusterResource.ps1 defines Get-ClvClusterResource' {
            $path = Join-Path $script:ModuleRoot 'Private\Get-ClvClusterResource.ps1'
            (Get-Content $path -Raw) | Should -Match 'function\s+Get-ClvClusterResource\b'
        }
        It 'orchestrator never calls Test-Cluster directly' {
            $direct = Select-String -Path $script:OrchestratorPath `
                -Pattern '(?<![-\w])Test-Cluster(?![-\w])'
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
            It "no source file invokes forbidden cmdlet: $cmd" {
                $pattern = "(?<![-\w])$([regex]::Escape($cmd))(?![-\w])"
                $offenders = Get-ChildItem -Path $script:ModuleRoot -Filter '*.ps1' -Recurse -File |
                    Where-Object { (Get-Content $_.FullName -Raw) -match $pattern } |
                    Select-Object -ExpandProperty FullName
                $offenders | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Rules §11 - Public Function Contract' {
        It 'manifest exports Invoke-ClusterValidator and Test-ClusterValidatorConfig' {
            $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
            $expected = @('Invoke-ClusterValidator', 'Test-ClusterValidatorConfig')
            @($manifest.FunctionsToExport | Sort-Object) | Should -Be ($expected | Sort-Object)
        }
        It 'manifest does not export cmdlets, variables, or aliases' {
            $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
            $manifest.CmdletsToExport   | Should -BeNullOrEmpty
            $manifest.VariablesToExport | Should -BeNullOrEmpty
            $manifest.AliasesToExport   | Should -BeNullOrEmpty
        }
        It 'every public file matches a manifest export' {
            $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
            $publicFiles = Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Public') -Filter '*.ps1' -File
            foreach ($f in $publicFiles) {
                $f.BaseName | Should -BeIn $manifest.FunctionsToExport `
                    -Because "public file '$($f.Name)' must be listed in FunctionsToExport"
            }
        }
        It 'private helpers all use the Clv prefix' {
            $privateRoot = Join-Path $script:ModuleRoot 'Private'
            $files = Get-ChildItem -Path $privateRoot -Filter '*.ps1' -File
            foreach ($f in $files) {
                $f.BaseName | Should -Match '^[A-Z][a-z]+-Clv[A-Z]\w*$' `
                    -Because "private helper '$($f.Name)' must use the Verb-ClvNoun pattern"
            }
        }
        It 'public functions do NOT carry the Clv prefix' {
            $publicFiles = Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Public') -Filter '*.ps1' -File
            foreach ($f in $publicFiles) {
                $f.BaseName | Should -Not -Match '-Clv' `
                    -Because "public functions use the full ClusterValidator brand, not the Clv private prefix"
            }
        }
    }

    Context 'Rules §12 - Manifest Discipline' {
        It 'manifest parses cleanly via Test-ModuleManifest' {
            $err = $null
            { $null = Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } |
                Should -Not -Throw
        }
        It 'declares a non-zero ModuleVersion' {
            $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
            [version]$manifest.ModuleVersion | Should -BeGreaterThan ([version]'0.0.0')
        }
        It 'declares a stable GUID' {
            $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
            { [guid]::Parse($manifest.GUID) } | Should -Not -Throw
        }
        It 'declares FailoverClusters as a required module' {
            $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
            $manifest.RequiredModules | Should -Contain 'FailoverClusters'
        }
        It 'declares minimum PowerShellVersion 5.1 or higher' {
            $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
            [version]$manifest.PowerShellVersion | Should -BeGreaterOrEqual ([version]'5.1')
        }
    }

    Context 'Roadmap Phase 1 - Audit & Observability' {
        It 'generates a correlation GUID' {
            $script:OrchestratorText | Should -Match '\[guid\]::NewGuid\(\)'
        }
        It 'starts and stops a transcript inside try/finally' {
            $script:OrchestratorText | Should -Match 'Start-Transcript'
            $script:OrchestratorText | Should -Match 'Stop-Transcript'
            $script:OrchestratorText | Should -Match 'finally\s*\{'
        }
        It 'uses Test-WSMan for reachability' {
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
    }

    Context 'Roadmap Phase 2 - Validation Depth' {
        It 'exposes -ExpectedQuorumType, -TimeSkewToleranceSeconds, -ForensicCaptureMinutes' {
            $paramNames = $script:FunctionAst.Body.ParamBlock.Parameters.Name.VariablePath.UserPath
            $paramNames | Should -Contain 'ExpectedQuorumType'
            $paramNames | Should -Contain 'TimeSkewToleranceSeconds'
            $paramNames | Should -Contain 'ForensicCaptureMinutes'
        }
        It 'invokes Get-ClusterQuorum, Get-Cluster, Get-HotFix, Get-CimInstance, Get-ClusterLog' {
            $script:OrchestratorText | Should -Match '(?<![-\w])Get-ClusterQuorum(?![-\w])'
            $script:OrchestratorText | Should -Match '(?<![-\w])Get-Cluster\b\s*\|'
            $script:OrchestratorText | Should -Match '(?<![-\w])Get-HotFix(?![-\w])'
            $script:OrchestratorText | Should -Match '(?<![-\w])Get-CimInstance(?![-\w])'
            $script:OrchestratorText | Should -Match '(?<![-\w])Get-ClusterLog(?![-\w])'
        }
    }

    Context 'Roadmap Phase 3 - Security Hardening' {
        It 'exposes -Credential, -CredentialSecretName, -HardenReportAcl' {
            $paramNames = $script:FunctionAst.Body.ParamBlock.Parameters.Name.VariablePath.UserPath
            $paramNames | Should -Contain 'Credential'
            $paramNames | Should -Contain 'CredentialSecretName'
            $paramNames | Should -Contain 'HardenReportAcl'
        }
        It 'enforces FullLanguage mode preflight' {
            $script:OrchestratorText | Should -Match 'LanguageMode\s+-ne\s+''FullLanguage'''
        }
        It 'resolves credentials via Microsoft.PowerShell.SecretManagement' {
            $script:OrchestratorText | Should -Match 'Microsoft\.PowerShell\.SecretManagement'
            $script:OrchestratorText | Should -Match '(?<![-\w])Get-Secret(?![-\w])'
        }
        It 'hardens the report directory DACL on demand' {
            $script:OrchestratorText | Should -Match 'SetAccessRuleProtection'
            $script:OrchestratorText | Should -Match 'NT AUTHORITY\\SYSTEM'
            $script:OrchestratorText | Should -Match 'BUILTIN\\Administrators'
        }
        It 'contains no hardcoded plaintext credentials' {
            $script:OrchestratorText | Should -Not -Match 'ConvertTo-SecureString[^|]+-AsPlainText'
            $script:OrchestratorText | Should -Not -Match '\$pass(word)?\s*=\s*[''"][^''"]+[''"]'
        }
    }

    Context 'Rules §7 - Error Category Enforcement (1.1.0)' {
        It 'Add-ClvResult declares a [ValidateSet] -Category parameter' {
            $addResultPath = Join-Path $script:ModuleRoot 'Private\Add-ClvResult.ps1'
            $text = Get-Content $addResultPath -Raw
            $text | Should -Match '\[ValidateSet\(\s*''ConnectionError'''
            $text | Should -Match '\[string\]\$Category'
        }

        It 'Add-ClvResult throws when Status=Fail|Warn and -Category is omitted' {
            $addResultPath = Join-Path $script:ModuleRoot 'Private\Add-ClvResult.ps1'
            $text = Get-Content $addResultPath -Raw
            $text | Should -Match 'Status\s+-in\s+''Fail'',\s*''Warn''\s+-and\s+-not\s+\$Category'
        }

        It 'every domain category from Rules §7 appears at least once in the orchestrator' {
            # Smoke check that the source actually exercises the vocabulary
            # we claim to enforce. ConnectionError, ConfigurationError,
            # HandledSkip, Unknown, and PermissionDenied are excluded —
            # they're catch-all / cross-cutting categories not tied to a
            # specific domain phase.
            $domain = @(
                'ModuleMissingError',
                'StorageInventoryError',
                'StorageTopologyError',
                'MpioConfigurationError',
                'ReservationConflict',
                'QuorumStateError',
                'ClusterHeartbeatError',
                'TimeSkewError',
                'PendingRebootDetected',
                'HotfixParityError',
                'ServiceAccountError',
                'AffinityViolation',
                'TestClusterFailure'
            )
            foreach ($cat in $domain) {
                $script:OrchestratorText | Should -Match "(?<![\w])$cat(?![\w])" `
                    -Because "Rules §7 category '$cat' must appear at a Fail/Warn call site"
            }
        }

        It 'every Fail/Warn call site in the orchestrator carries a -Category (AST scan)' {
            $calls = $script:Ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Add-ClvResult'
            }, $true)

            $offenders = foreach ($call in $calls) {
                # Walk the command elements to extract -Status / -Category
                $elements = $call.CommandElements
                $status   = $null
                $hasCategory = $false
                for ($i = 1; $i -lt $elements.Count - 1; $i++) {
                    $e = $elements[$i]
                    if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
                        switch ($e.ParameterName) {
                            'Status'   { $status = $elements[$i + 1].Value }
                            'Category' { $hasCategory = $true }
                        }
                    }
                }
                if ($status -in 'Fail','Warn' -and -not $hasCategory) {
                    "$($call.Extent.File):$($call.Extent.StartLineNumber)"
                }
            }
            $offenders | Should -BeNullOrEmpty -Because 'Rules §7: Fail and Warn require -Category'
        }
    }

    Context 'Phase 11 VMware (1.2.0)' {
        It 'exposes -VCenterServer and -VCenterCredentialSecretName' {
            $paramNames = $script:FunctionAst.Body.ParamBlock.Parameters.Name.VariablePath.UserPath
            $paramNames | Should -Contain 'VCenterServer'
            $paramNames | Should -Contain 'VCenterCredentialSecretName'
        }
        It 'gates the phase on PowerCLI being installed' {
            $script:OrchestratorText | Should -Match "Get-Module\s+-ListAvailable\s+-Name\s+'VMware\.VimAutomation\.Core'"
        }
        It 'connects via Connect-VIServer and disconnects in finally' {
            $script:OrchestratorText | Should -Match '(?<![-\w])Connect-VIServer(?![-\w])'
            $script:OrchestratorText | Should -Match '(?<![-\w])Disconnect-VIServer(?![-\w])'
            # The Disconnect must live in the finally block of the VMware phase.
            $finallyIdx     = $script:OrchestratorText.IndexOf('finally {', $script:OrchestratorText.IndexOf('# Phase 11: VMware'))
            $disconnectIdx  = $script:OrchestratorText.IndexOf('Disconnect-VIServer')
            $disconnectIdx  | Should -BeGreaterThan $finallyIdx
        }
        It 'queries DRS rules via Get-DrsRule' {
            $script:OrchestratorText | Should -Match '(?<![-\w])Get-DrsRule(?![-\w])'
        }
        It 'uses the Get-ClvHostColocation pure helper' {
            $script:OrchestratorText | Should -Match 'Get-ClvHostColocation\s+-VMs'
        }
        It 'Get-ClvHostColocation private file exists' {
            $path = Join-Path $script:ModuleRoot 'Private\Get-ClvHostColocation.ps1'
            Test-Path -Path $path -PathType Leaf | Should -BeTrue
        }
    }

    Context 'Roadmap Phase 4 - Scale & Operability' {
        It 'exposes -ConfigPath' {
            $paramNames = $script:FunctionAst.Body.ParamBlock.Parameters.Name.VariablePath.UserPath
            $paramNames | Should -Contain 'ConfigPath'
        }
        It 'protects -Nodes, -Credential, and -ConfigPath from config-file override' {
            $script:OrchestratorText | Should -Match "protectedKeys\s*=\s*'Nodes',\s*'Credential',\s*'ConfigPath'"
        }
        It 'uses the pure helpers in phases 7, 9, 10' {
            $script:OrchestratorText | Should -Match 'Get-ClvTimeSkew\s+-Samples'
            $script:OrchestratorText | Should -Match 'Get-ClvHotFixDrift\s+-Reports'
            $script:OrchestratorText | Should -Match 'Get-ClvServiceAccountIssues\s+-Reports'
        }
    }

    Context 'Back-compat wrapper script' {
        It 'exists at the original path' {
            Test-Path -Path $script:WrapperPath -PathType Leaf | Should -BeTrue
        }
        It 'imports the module and forwards $args to Invoke-ClusterValidator' {
            $wrapper = Get-Content $script:WrapperPath -Raw
            $wrapper | Should -Match 'Import-Module'
            $wrapper | Should -Match 'Invoke-ClusterValidator\s+@args'
        }
        It 'exits 0 on success and 1 on failure' {
            $wrapper = Get-Content $script:WrapperPath -Raw
            $wrapper | Should -Match 'exit\s+0'
            $wrapper | Should -Match 'exit\s+1'
        }
    }
}
