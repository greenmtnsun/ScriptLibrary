function Add-ClvResult {
    # Single point where every result record is constructed. Enforces
    # the §7 error-category vocabulary: every Fail/Warn record must
    # carry one of the named categories so SIEM filtering and runbook
    # cross-references work without parsing free-text Message fields.
    # Pass and Info records may omit Category (the test passed; nothing
    # to classify).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Phase,

        [Parameter(Mandatory)]
        [ValidateSet('Pass', 'Warn', 'Fail', 'Info')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet(
            'ConnectionError',
            'ModuleMissingError',
            'PermissionDenied',
            'StorageInventoryError',
            'StorageTopologyError',
            'MpioConfigurationError',
            'ReservationConflict',
            'QuorumStateError',
            'ClusterHeartbeatError',
            'TimeSkewError',
            'HotfixParityError',
            'PendingRebootDetected',
            'ServiceAccountError',
            'AffinityViolation',
            'TestClusterFailure',
            'ConfigurationError',
            'HandledSkip',
            'Unknown'
        )]
        [string]$Category,

        [object]$Data
    )

    # Rules §7: Fail and Warn records must carry an explicit category.
    # Misclassification masks the real signal in SIEM and is treated
    # as a bug — this guard catches the omission at the call site.
    if ($Status -in 'Fail', 'Warn' -and -not $Category) {
        throw "Add-ClvResult: Status='$Status' requires -Category (Rules §7). Phase='$Phase', Message='$Message'."
    }

    $script:results.Add([pscustomobject]@{
        CorrelationId = $script:correlationId
        Timestamp     = (Get-Date).ToUniversalTime().ToString('o')
        Phase         = $Phase
        Status        = $Status
        Category      = $Category
        Message       = $Message
        Data          = $Data
    })

    $color = switch ($Status) {
        'Pass'  { 'Green'  }
        'Warn'  { 'Yellow' }
        'Fail'  { 'Red'    }
        default { 'Cyan'   }
    }
    $tag = if ($Category) { "[$Status/$Category]" } else { "[$Status]" }
    Write-Host "$tag $Phase :: $Message" -ForegroundColor $color
}
