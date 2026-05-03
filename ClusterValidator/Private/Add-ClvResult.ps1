function Add-ClvResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Phase,
        [Parameter(Mandatory)] [ValidateSet('Pass', 'Warn', 'Fail', 'Info')] [string]$Status,
        [Parameter(Mandatory)] [string]$Message,
        [object]$Data
    )

    # Reads $script:correlationId and $script:results, populated by the
    # public function at the start of a run. These live in the module's
    # script scope and are shared across every helper.
    $script:results.Add([pscustomobject]@{
        CorrelationId = $script:correlationId
        Timestamp     = (Get-Date).ToUniversalTime().ToString('o')
        Phase         = $Phase
        Status        = $Status
        Message       = $Message
        Data          = $Data
    })

    $color = switch ($Status) {
        'Pass'  { 'Green'  }
        'Warn'  { 'Yellow' }
        'Fail'  { 'Red'    }
        default { 'Cyan'   }
    }
    Write-Host "[$Status] $Phase :: $Message" -ForegroundColor $color
}
