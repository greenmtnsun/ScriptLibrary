# ClusterValidator module loader.
#
# This is the only file in this project allowed to use $PSScriptRoot
# (per the §3 carve-out for module loaders in ClusterValidator-Rules.md).
# Module load runs through Import-Module, which sets $PSScriptRoot
# reliably; the dot-sourcing/remoting/CmdExec hazards that motivate the
# §3 ban for scripts do not apply here.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$private = @(Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue)
$public  = @(Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1"  -ErrorAction SilentlyContinue)

# Private files load first so public functions can reference private
# helpers during their own parse.
foreach ($file in @($private) + @($public)) {
    try {
        . $file.FullName
    } catch {
        throw "Failed to load $($file.FullName): $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function $public.BaseName
