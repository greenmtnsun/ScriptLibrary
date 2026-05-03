function Test-ClvElevation {
    # Returns $true when the current process is running with
    # Administrator membership. Extracted into its own helper so the
    # integration tests can mock it without needing an elevated runner.
    # Not exported.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}
