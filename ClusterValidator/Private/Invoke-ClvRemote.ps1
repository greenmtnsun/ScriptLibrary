function Invoke-ClvRemote {
    # Single mock point for Invoke-Command per ClusterValidator-Rules.md §5.
    # Two parameter sets:
    #   Single  - a single PSSession for per-node phases
    #   Many    - an array of PSSessions for parallel fan-out reads
    [CmdletBinding(DefaultParameterSetName = 'Single')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Single')]
        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory, ParameterSetName = 'Many')]
        [System.Management.Automation.Runspaces.PSSession[]]$Sessions,

        [Parameter(Mandatory)] [scriptblock]$ScriptBlock,

        [object[]]$ArgumentList
    )
    if ($PSCmdlet.ParameterSetName -eq 'Many') {
        Invoke-Command -Session $Sessions -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
    } else {
        Invoke-Command -Session $Session  -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
    }
}
