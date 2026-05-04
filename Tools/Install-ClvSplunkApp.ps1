#Requires -Version 5.1

<#
.SYNOPSIS
    Build (and optionally install) the ClusterValidator-TA Splunk app
    from the .conf / .xml artifacts under .\splunk\.

.DESCRIPTION
    Lays the loose .conf files and dashboard XML out in the canonical
    Splunk app directory structure:

        ClusterValidator-TA\
        ├── default\
        │   ├── app.conf                  (generated)
        │   ├── inputs.conf               (only if -IncludeInputs; usually
        │   │                              for UF, not the search head)
        │   ├── props.conf
        │   ├── transforms.conf
        │   ├── eventtypes.conf
        │   ├── tags.conf
        │   ├── savedsearches.conf
        │   └── data\ui\
        │       ├── views\cluster_validator.xml
        │       └── nav\default.xml       (generated)
        └── metadata\
            └── default.meta              (generated)

    By default the script builds the app at .\dist\ClusterValidator-TA\
    so a Splunk admin can review before deploying. With -SplunkHome the
    script copies the built app directly into the live Splunk install
    at $SplunkHome\etc\apps\ClusterValidator-TA\. With -Restart it
    restarts Splunkd afterward.

    Idempotent: re-running cleanly replaces the existing build/install.
    Supports -WhatIf for dry runs.

.PARAMETER SourceRoot
    Repo root that contains the splunk\ folder. Defaults to the current
    working directory.

.PARAMETER OutputPath
    Build destination. The app is built at <OutputPath>\<AppName>\.
    Defaults to .\dist\.

.PARAMETER AppName
    Splunk app folder name. Defaults to ClusterValidator-TA.

.PARAMETER Version
    Version string written to app.conf [launcher] version=. Defaults to
    1.5.0 (matches the ClusterValidator module manifest).

.PARAMETER IncludeInputs
    Include inputs.conf in the built app. By convention Splunk inputs
    live on the Universal Forwarder rather than the search head, so by
    default we omit it. Set this only if you're building a single all-
    in-one app for a small / single-host deployment.

.PARAMETER SplunkHome
    Path to the Splunk install (e.g. 'C:\Program Files\Splunk'). When
    set, the built app is copied to $SplunkHome\etc\apps\<AppName>\.
    Existing install at that path is replaced (after -WhatIf gate).

.PARAMETER Restart
    With -SplunkHome, restart Splunkd after the copy completes via
    'splunk.exe restart'.

.EXAMPLE
    .\Tools\Install-ClvSplunkApp.ps1

    Builds .\dist\ClusterValidator-TA\ from .\splunk\. Hand the folder
    to your Splunk admin.

.EXAMPLE
    .\Tools\Install-ClvSplunkApp.ps1 -SplunkHome 'C:\Program Files\Splunk' -Restart

    Builds, copies into the live Splunk install, restarts Splunkd.

.EXAMPLE
    .\Tools\Install-ClvSplunkApp.ps1 -SplunkHome 'C:\Program Files\Splunk' -WhatIf

    Show what would happen without changing anything.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SourceRoot = (Get-Location).Path,

    [string]$OutputPath = (Join-Path (Get-Location).Path 'dist'),

    [ValidatePattern('^[A-Za-z][\w\-]+$')]
    [string]$AppName = 'ClusterValidator-TA',

    [string]$Version = '1.5.0',

    [switch]$IncludeInputs,

    [string]$SplunkHome,

    [switch]$Restart
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Source layout sanity
# ---------------------------------------------------------------------------
$splunkSrc     = Join-Path $SourceRoot 'splunk'
$dashboardSrc  = Join-Path $splunkSrc  'dashboards'

if (-not (Test-Path -Path $splunkSrc -PathType Container)) {
    throw "Splunk source folder not found at '$splunkSrc'. Run this from the repo root, or pass -SourceRoot."
}
if (-not (Test-Path -Path $dashboardSrc -PathType Container)) {
    throw "Expected dashboards folder at '$dashboardSrc' but it doesn't exist."
}

# ---------------------------------------------------------------------------
# Build target paths
# ---------------------------------------------------------------------------
$appRoot     = Join-Path $OutputPath $AppName
$defaultDir  = Join-Path $appRoot   'default'
$metadataDir = Join-Path $appRoot   'metadata'
$viewsDir    = Join-Path $defaultDir 'data\ui\views'
$navDir      = Join-Path $defaultDir 'data\ui\nav'

# ---------------------------------------------------------------------------
# Replace any prior build at the target path
# ---------------------------------------------------------------------------
if (Test-Path -Path $appRoot) {
    if ($PSCmdlet.ShouldProcess($appRoot, 'Remove existing app build')) {
        Remove-Item -Path $appRoot -Recurse -Force
    }
}

if ($PSCmdlet.ShouldProcess($appRoot, 'Create app folder layout')) {
    foreach ($d in @($defaultDir, $metadataDir, $viewsDir, $navDir)) {
        $null = New-Item -Path $d -ItemType Directory -Force
    }
}

# ---------------------------------------------------------------------------
# Copy .conf files. Skip *.example (those are UF-side templates, not app
# defaults) unless -IncludeInputs was set.
# ---------------------------------------------------------------------------
$conf = Get-ChildItem -Path $splunkSrc -Filter '*.conf' -File

if ($IncludeInputs) {
    # Promote inputs.conf.example -> inputs.conf when explicitly requested.
    $inputsExample = Get-ChildItem -Path $splunkSrc -Filter 'inputs.conf.example' -File
    foreach ($f in $inputsExample) {
        if ($PSCmdlet.ShouldProcess((Join-Path $defaultDir 'inputs.conf'), 'Promote inputs.conf.example')) {
            Copy-Item -Path $f.FullName -Destination (Join-Path $defaultDir 'inputs.conf') -Force
        }
    }
}

foreach ($f in $conf) {
    if ($PSCmdlet.ShouldProcess((Join-Path $defaultDir $f.Name), "Copy $($f.Name)")) {
        Copy-Item -Path $f.FullName -Destination (Join-Path $defaultDir $f.Name) -Force
    }
}

# ---------------------------------------------------------------------------
# Copy dashboards into data\ui\views
# ---------------------------------------------------------------------------
foreach ($view in (Get-ChildItem -Path $dashboardSrc -Filter '*.xml' -File)) {
    if ($PSCmdlet.ShouldProcess((Join-Path $viewsDir $view.Name), "Copy dashboard $($view.Name)")) {
        Copy-Item -Path $view.FullName -Destination (Join-Path $viewsDir $view.Name) -Force
    }
}

# ---------------------------------------------------------------------------
# Generate app.conf - required for any Splunk app
# ---------------------------------------------------------------------------
$appConf = @"
[install]
is_configured = 1
state = enabled

[ui]
is_visible = 1
label = ClusterValidator

[launcher]
author = ScriptLibrary maintainers
description = SQL FCI cluster health validator. Dashboard + alerts + parsing config for Invoke-ClusterValidator output via Windows Event Log (path A) or JSON file ingestion (path B).
version = $Version

[package]
id = $AppName
"@

if ($PSCmdlet.ShouldProcess((Join-Path $defaultDir 'app.conf'), 'Generate app.conf')) {
    $appConf | Set-Content -Path (Join-Path $defaultDir 'app.conf') -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Generate metadata\default.meta - exports the views/eventtypes/tags
# system-wide so other apps can reference them.
# ---------------------------------------------------------------------------
$meta = @"
[]
access = read : [ * ], write : [ admin, sc_admin ]
export = system

[views]
export = system

[eventtypes]
export = system

[tags]
export = system

[savedsearches]
export = system
"@

if ($PSCmdlet.ShouldProcess((Join-Path $metadataDir 'default.meta'), 'Generate default.meta')) {
    $meta | Set-Content -Path (Join-Path $metadataDir 'default.meta') -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Generate nav\default.xml - dashboard appears as the default app view
# ---------------------------------------------------------------------------
$nav = @"
<nav search_view="search">
  <view name="cluster_validator" default="true" label="Health Overview" />
  <view name="search" />
</nav>
"@

if ($PSCmdlet.ShouldProcess((Join-Path $navDir 'default.xml'), 'Generate nav\default.xml')) {
    $nav | Set-Content -Path (Join-Path $navDir 'default.xml') -Encoding UTF8
}

Write-Host ''
Write-Host "Built Splunk app at: $appRoot" -ForegroundColor Green
Write-Host "Files:" -ForegroundColor Cyan
Get-ChildItem -Path $appRoot -Recurse -File |
    ForEach-Object { '  ' + $_.FullName.Substring($appRoot.Length + 1) }

# ---------------------------------------------------------------------------
# Optional: install to a live Splunk
# ---------------------------------------------------------------------------
if ($SplunkHome) {
    if (-not (Test-Path -Path $SplunkHome -PathType Container)) {
        throw "ConfigurationError: -SplunkHome '$SplunkHome' does not exist."
    }
    $appsDir     = Join-Path $SplunkHome 'etc\apps'
    $installPath = Join-Path $appsDir   $AppName

    if (-not (Test-Path -Path $appsDir -PathType Container)) {
        throw "ConfigurationError: '$appsDir' not found - is '$SplunkHome' really a Splunk install?"
    }

    if (Test-Path -Path $installPath) {
        if ($PSCmdlet.ShouldProcess($installPath, 'Remove existing app install')) {
            Remove-Item -Path $installPath -Recurse -Force
        }
    }

    if ($PSCmdlet.ShouldProcess($installPath, "Install $AppName to Splunk")) {
        Copy-Item -Path $appRoot -Destination $appsDir -Recurse -Force
        Write-Host ''
        Write-Host "Installed to: $installPath" -ForegroundColor Green
    }

    if ($Restart) {
        $splunkExe = Join-Path $SplunkHome 'bin\splunk.exe'
        if (-not (Test-Path -Path $splunkExe -PathType Leaf)) {
            Write-Warning "splunk.exe not found at '$splunkExe'; restart Splunkd manually."
        } elseif ($PSCmdlet.ShouldProcess('Splunkd', 'Restart')) {
            Write-Host ''
            Write-Host 'Restarting Splunkd...' -ForegroundColor Cyan
            & $splunkExe restart
        }
    } else {
        Write-Host ''
        Write-Host 'Skip restart (no -Restart). Restart Splunkd manually for changes to take effect.' -ForegroundColor Yellow
    }
}
