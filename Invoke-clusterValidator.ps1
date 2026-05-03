#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Backwards-compatible wrapper for the ClusterValidator module.

.DESCRIPTION
    The cluster validator now ships as a PowerShell module under
    .\ClusterValidator\. This wrapper exists so legacy SQL Agent CmdExec
    steps and ad-hoc invocations of Invoke-clusterValidator.ps1 keep
    working unchanged. New code should call:

        Import-Module .\ClusterValidator\ClusterValidator.psd1
        Invoke-ClusterValidator -Nodes ...

    The wrapper has no parameter declarations of its own. Every
    argument supplied at the command line is forwarded verbatim to
    Invoke-ClusterValidator via $args splatting, so the contract is
    "whatever the function accepts, the wrapper accepts too" - no
    duplication, no drift.

    Exit code: 0 if no Fail records, 1 otherwise. CmdExec-friendly.

.NOTES
    Companion docs:
        ClusterValidator-Rules.md   (engineering rules)
        ClusterValidator-Roadmap.md (enterprise readiness phases)
#>

# Locate the module relative to this wrapper file. Per Rules §3 we
# don't use $PSScriptRoot in scripts; $MyInvocation is the canonical
# script-context analog.
$wrapperDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath = Join-Path $wrapperDir 'ClusterValidator\ClusterValidator.psd1'

if (-not (Test-Path -Path $modulePath -PathType Leaf)) {
    Write-Error "ConfigurationError: ClusterValidator module not found at '$modulePath'."
    exit 2
}

Import-Module -Name $modulePath -Force -ErrorAction Stop

$result = Invoke-ClusterValidator @args

if ($result.HasFail) { exit 1 } else { exit 0 }
