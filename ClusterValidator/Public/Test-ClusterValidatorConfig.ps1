function Test-ClusterValidatorConfig {
<#
.SYNOPSIS
    Statically validate a ClusterValidator config JSON file.

.DESCRIPTION
    Reads a JSON config file and checks each key against the parameter
    schema of Invoke-ClusterValidator: name match, type assignability,
    ValidateSet membership, ValidateRange bounds, and protected-key
    discipline (Nodes, Credential, ConfigPath are never config-
    overridable).

    Designed for CI use: run this against every Config\*.json in the
    repo before merge so typos and stale keys are caught at PR time
    rather than at the next 03:00 AM scheduled run.

    Returns a pscustomobject with:
      ConfigPath  - path to the config that was checked
      Valid       - $true if no Error-severity issues were found
      Issues      - structured array of issue records, each with
                    Severity, Key, Issue, Message

    Keys whose name starts with an underscore (e.g. "_comment") are
    treated as documentation and ignored.

.PARAMETER ConfigPath
    Path to the JSON config file. Must exist.

.PARAMETER Strict
    Reserved for future warning-class checks. Currently a no-op.

.EXAMPLE
    Test-ClusterValidatorConfig -ConfigPath .\Config\prod.json

.EXAMPLE
    # Lint every config in CI; fail the build on any error
    $bad = Get-ChildItem .\Config\*.json | ForEach-Object {
        Test-ClusterValidatorConfig -ConfigPath $_.FullName
    } | Where-Object { -not $_.Valid }
    if ($bad) { exit 1 }
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
        [string]$ConfigPath,

        [switch]$Strict
    )

    # Parse JSON. Any parse failure is a hard Error - the file is unusable.
    try {
        $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [pscustomobject]@{
            ConfigPath = $ConfigPath
            Valid      = $false
            Issues     = @([pscustomobject]@{
                Severity = 'Error'
                Key      = '<file>'
                Issue    = 'JsonParseError'
                Message  = "Failed to parse '$ConfigPath' as JSON: $($_.Exception.Message)"
            })
        }
    }

    $cmd = Get-Command -Name Invoke-ClusterValidator -ErrorAction Stop
    $params = $cmd.Parameters

    # Drop common parameters (Verbose, Debug, ErrorAction, etc.) - they
    # exist on every advanced function but are not part of the validator's
    # config surface.
    $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) +
              @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)

    $protected = 'Nodes', 'Credential', 'ConfigPath'
    $issues = New-Object System.Collections.Generic.List[object]

    foreach ($prop in $config.PSObject.Properties) {
        $name  = $prop.Name
        $value = $prop.Value

        # Underscore-prefixed keys are JSON-style comments; ignore.
        if ($name.StartsWith('_')) { continue }

        # Protected keys are never overridable by config.
        if ($name -in $protected) {
            $issues.Add([pscustomobject]@{
                Severity = 'Error'
                Key      = $name
                Issue    = 'ProtectedKey'
                Message  = "'$name' is not config-overridable. Remove it from the config and pass it on the command line."
            })
            continue
        }

        # Unknown key (typo or stale).
        if (-not $params.ContainsKey($name) -or $name -in $common) {
            $issues.Add([pscustomobject]@{
                Severity = 'Error'
                Key      = $name
                Issue    = 'UnknownParameter'
                Message  = "'$name' is not a parameter of Invoke-ClusterValidator."
            })
            continue
        }

        $paramInfo = $params[$name]
        $expectedType = $paramInfo.ParameterType

        # Type assignability. LanguagePrimitives.ConvertTo handles the
        # standard PS coercion rules (string<->int, JSON bool->switch, etc.)
        # so we don't reinvent them.
        try {
            $null = [System.Management.Automation.LanguagePrimitives]::ConvertTo($value, $expectedType)
        } catch {
            $issues.Add([pscustomobject]@{
                Severity = 'Error'
                Key      = $name
                Issue    = 'TypeMismatch'
                Message  = "'$name' = $($value | ConvertTo-Json -Compress -Depth 3) is not assignable to $($expectedType.FullName)."
            })
            continue
        }

        # ValidateSet membership.
        $vs = $paramInfo.Attributes |
              Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
              Select-Object -First 1
        if ($vs) {
            $checkValues = if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
                @($value)
            } else {
                @($value)
            }
            foreach ($v in $checkValues) {
                if ($v -notin $vs.ValidValues) {
                    $issues.Add([pscustomobject]@{
                        Severity = 'Error'
                        Key      = $name
                        Issue    = 'InvalidValue'
                        Message  = "'$name' value '$v' is not in the allowed set: $($vs.ValidValues -join ', ')."
                    })
                }
            }
        }

        # ValidateRange bounds.
        $vr = $paramInfo.Attributes |
              Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] } |
              Select-Object -First 1
        if ($vr -and ($value -is [int] -or $value -is [double] -or $value -is [long])) {
            if ($value -lt $vr.MinRange -or $value -gt $vr.MaxRange) {
                $issues.Add([pscustomobject]@{
                    Severity = 'Error'
                    Key      = $name
                    Issue    = 'OutOfRange'
                    Message  = "'$name' = $value is outside [$($vr.MinRange)..$($vr.MaxRange)]."
                })
            }
        }
    }

    [pscustomobject]@{
        ConfigPath = $ConfigPath
        Valid      = (-not (@($issues | Where-Object Severity -eq 'Error')).Count)
        Issues     = $issues.ToArray()
    }
}
