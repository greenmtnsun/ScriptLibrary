function Invoke-ClvRemote {
    # Single mock point for Invoke-Command per ClusterValidator-Rules.md §5.
    # Two parameter sets:
    #   Single  - a single PSSession for per-node phases
    #   Many    - an array of PSSessions for parallel fan-out reads
    #
    # The -Session/-Sessions parameters are deliberately typed as [object]
    # rather than [PSSession] so integration tests can mock this wrapper
    # with stub session objects. Production type discipline still holds:
    # the inner Invoke-Command -Session call requires a real PSSession,
    # which is what gets passed at runtime.
    [CmdletBinding(DefaultParameterSetName = 'Single')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Single')]
        [ValidateNotNull()]
        $Session,

        [Parameter(Mandatory, ParameterSetName = 'Many')]
        [ValidateNotNullOrEmpty()]
        [object[]]$Sessions,

        [Parameter(Mandatory)] [scriptblock]$ScriptBlock,

        [object[]]$ArgumentList
    )
    if ($PSCmdlet.ParameterSetName -eq 'Many') {
        Invoke-Command -Session $Sessions -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
    } else {
        Invoke-Command -Session $Session  -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
    }
}
