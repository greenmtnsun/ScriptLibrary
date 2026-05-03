[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot,

    [ValidateSet('Static', 'Unit', 'Integration', 'Acceptance', 'All')]
    [string]$Category = 'All'
)

# Pester runner for the cluster validator project.
# Loads Pester 5.x, discovers tests under <ProjectRoot>\Tests, and injects
# the explicit -ProjectRoot parameter into each test file (per
# ClusterValidator-Rules.md §2 - no $PSScriptRoot).

$ErrorActionPreference = 'Stop'

$pesterModule = Get-Module -ListAvailable -Name Pester |
    Where-Object Version -ge '5.0.0' |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $pesterModule) {
    throw 'Pester 5.x is required. Install with: Install-Module -Name Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force'
}
Import-Module $pesterModule -Force

$testsRoot = Join-Path $ProjectRoot 'Tests'
$path = if ($Category -eq 'All') { $testsRoot } else { Join-Path $testsRoot $Category }

if (-not (Test-Path -Path $path)) {
    Write-Warning "No tests found at $path"
    return
}

$container = New-PesterContainer -Path $path -Data @{ ProjectRoot = $ProjectRoot }

$config = New-PesterConfiguration
$config.Run.Container    = $container
$config.Run.PassThru     = $true
$config.Output.Verbosity = 'Detailed'

$result = Invoke-Pester -Configuration $config

if ($result.FailedCount -gt 0) {
    exit 1
}
exit 0
