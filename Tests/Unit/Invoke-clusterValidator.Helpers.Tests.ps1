[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot
)

# Unit suite for the pure-logic helpers inside Invoke-clusterValidator.ps1.
# We AST-extract just the helper functions and dot-source them into the
# test scope, so we never bind the orchestrator's mandatory -Nodes
# parameter and never need a live cluster.

Describe 'Invoke-clusterValidator helpers - Unit' {

    BeforeAll {
        $orchPath = Join-Path $ProjectRoot 'Invoke-clusterValidator.ps1'

        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $orchPath, [ref]$tokens, [ref]$errors)
        if ($errors) {
            throw "Orchestrator failed to parse: $($errors | ForEach-Object Message | Out-String)"
        }

        $wanted = @(
            'Get-ClvTimeSkew',
            'Get-ClvHotFixDrift',
            'Get-ClvServiceAccountIssues'
        )

        $found = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true) | Where-Object { $_.Name -in $wanted }

        foreach ($fn in $found) {
            $sb = [scriptblock]::Create($fn.Extent.Text)
            . $sb
        }
    }

    Context 'Get-ClvTimeSkew' {
        It 'returns 0 skew when all samples are equal' {
            $now = [datetime]::UtcNow
            $samples = @(
                [pscustomobject]@{ ComputerName = 'A'; UtcNow = $now },
                [pscustomobject]@{ ComputerName = 'B'; UtcNow = $now }
            )
            $r = Get-ClvTimeSkew -Samples $samples
            $r.Skew        | Should -Be 0
            $r.SampleCount | Should -Be 2
        }

        It 'computes the spread between min and max in seconds' {
            $base = [datetime]::UtcNow
            $samples = @(
                [pscustomobject]@{ ComputerName = 'A'; UtcNow = $base },
                [pscustomobject]@{ ComputerName = 'B'; UtcNow = $base.AddSeconds(5) },
                [pscustomobject]@{ ComputerName = 'C'; UtcNow = $base.AddSeconds(2) }
            )
            $r = Get-ClvTimeSkew -Samples $samples
            $r.Skew | Should -Be 5.0
        }

        It 'returns null skew with fewer than 2 valid samples' {
            $r = Get-ClvTimeSkew -Samples @(
                [pscustomobject]@{ ComputerName = 'A'; UtcNow = [datetime]::UtcNow }
            )
            $r.Skew        | Should -BeNullOrEmpty
            $r.SampleCount | Should -Be 1
        }

        It 'ignores samples whose UtcNow is null' {
            $samples = @(
                [pscustomobject]@{ ComputerName = 'A'; UtcNow = $null },
                [pscustomobject]@{ ComputerName = 'B'; UtcNow = [datetime]::UtcNow }
            )
            $r = Get-ClvTimeSkew -Samples $samples
            $r.SampleCount | Should -Be 1
            $r.Skew        | Should -BeNullOrEmpty
        }
    }

    Context 'Get-ClvHotFixDrift' {
        It 'reports no drift when every node has the same KB set' {
            $reports = @(
                [pscustomobject]@{ ComputerName = 'A'; HotFixIDs = @('KB1','KB2','KB3') },
                [pscustomobject]@{ ComputerName = 'B'; HotFixIDs = @('KB1','KB2','KB3') }
            )
            $r = Get-ClvHotFixDrift -Reports $reports
            $r.AllKbCount | Should -Be 3
            @($r.Drift).Count | Should -Be 0
        }

        It 'flags a node missing a KB the others have' {
            $reports = @(
                [pscustomobject]@{ ComputerName = 'A'; HotFixIDs = @('KB1','KB2','KB3') },
                [pscustomobject]@{ ComputerName = 'B'; HotFixIDs = @('KB1','KB2') }
            )
            $r = Get-ClvHotFixDrift -Reports $reports
            @($r.Drift).Count             | Should -Be 1
            $r.Drift[0].ComputerName      | Should -Be 'B'
            $r.Drift[0].Missing           | Should -Be @('KB3')
        }

        It 'flags multiple nodes missing different KBs' {
            $reports = @(
                [pscustomobject]@{ ComputerName = 'A'; HotFixIDs = @('KB1','KB2') },
                [pscustomobject]@{ ComputerName = 'B'; HotFixIDs = @('KB2','KB3') }
            )
            $r = Get-ClvHotFixDrift -Reports $reports
            $r.AllKbCount    | Should -Be 3
            @($r.Drift).Count | Should -Be 2
        }
    }

    Context 'Get-ClvServiceAccountIssues' {
        It 'returns empty when accounts are uniform and non-builtin' {
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

        It 'flags built-in accounts (LocalSystem, etc.)' {
            $reports = @(
                [pscustomobject]@{ ComputerName = 'A'; Services = @(
                    [pscustomobject]@{ Name = 'ClusSvc'; StartName = 'LocalSystem'; State = 'Running' }
                )}
            )
            $issues = Get-ClvServiceAccountIssues -Reports $reports
            @($issues).Count          | Should -Be 1
            $issues[0].Issue          | Should -Be 'BuiltInAccount'
            $issues[0].StartName      | Should -Be 'LocalSystem'
            $issues[0].ComputerName   | Should -Be 'A'
        }

        It 'flags account mismatches across nodes for the same service' {
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
            $mismatch.Count    | Should -Be 1
            $mismatch[0].Service | Should -Be 'MSSQL$INST'
        }

        It 'honors a custom -BuiltInAccounts list' {
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
