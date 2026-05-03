function Get-ClvTimeSkew {
    # Pure logic. Given an array of {ComputerName, UtcNow [datetime]},
    # returns the max-min spread in seconds plus the input bookkeeping.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]]$Samples
    )
    $valid = @($Samples | Where-Object { $_.UtcNow })
    if ($valid.Count -lt 2) {
        return [pscustomobject]@{
            Skew        = $null
            Min         = $null
            Max         = $null
            SampleCount = $valid.Count
        }
    }
    $min = ($valid.UtcNow | Measure-Object -Minimum).Minimum
    $max = ($valid.UtcNow | Measure-Object -Maximum).Maximum
    [pscustomobject]@{
        Skew        = [math]::Round(($max - $min).TotalSeconds, 3)
        Min         = $min
        Max         = $max
        SampleCount = $valid.Count
    }
}
