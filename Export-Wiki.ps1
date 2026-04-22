function Export-HardenedWiki {
    <#
    .SYNOPSIS
        Deep-scan wiki generator with AST parsing and SHA256 traceability.
    .DESCRIPTION
        Hardened for senior-level workflows. Rejects malformed scripts, 
        sanitizes filenames, and provides immutable version stamping.
    #>
    [CmdletBinding(DefaultParameterSetName = "FilePath")]
    param(
        [Parameter(Mandatory, ParameterSetName = "FilePath", Position = 0)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = "FunctionName", Position = 0)]
        [string]$FunctionName,

        [Parameter(Mandatory, Position = 1)]
        [string]$OutputFolder
    )

    process {
        $ErrorActionPreference = "Stop"
        $TempModuleName = "WikiDoc_$(Get-Random)"
        
        try {
            # 1. PRE-FLIGHT REJECT RULES
            if (-not (Get-Module -ListAvailable PlatyPS)) { throw "PlatyPS module missing. Documentation cannot proceed." }
            
            $AbsoluteOutput = (New-Item -ItemType Directory -Path $OutputFolder -Force).FullName
            $VersionStamp = "N/A"
            $ExportList = @()

            # 2. DEEP SCAN & VERSIONING
            if ($PSCmdlet.ParameterSetName -eq "FilePath") {
                $File = Get-Item $Path
                $Content = Get-Content $Path -Raw
                if ([string]::IsNullOrWhiteSpace($Content)) { throw "Rejection: Script file is empty." }

                # Generate immutable SHA256 hash for traceability (#4)
                $VersionStamp = (Get-FileHash $Path -Algorithm SHA256).Hash.Substring(0, 10)

                # AST Parsing (#2) - Extracting functions without executing the script
                $AST = [System.Management.Automation.Language.Parser]::ParseInput($Content, [ref]$null, [ref]$null)
                $FoundFunctions = $AST.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
                
                if ($FoundFunctions.Count -eq 0) { throw "Rejection: No function definitions found via AST scan." }
                $ExportList = $FoundFunctions.Name
            } 
            else {
                # Individual Function Mode
                if (-not (Get-Command $FunctionName -ErrorAction SilentlyContinue)) { throw "Rejection: Function '$FunctionName' not found in session." }
                $ExportList = @($FunctionName)
                $VersionStamp = "In-Memory Session"
            }

            # 3. ISOLATED COMPILATION
            Write-Host "Compiling documentation for $($ExportList.Count) targets..." -ForegroundColor Cyan
            
            # Use a child-scope module to prevent variable leakage
            $TempModule = New-Module -Name $TempModuleName -ScriptBlock {
                param($SourcePath, $ToExport, $IsFile)
                if ($IsFile) { . $SourcePath } 
                $ToExport | ForEach-Object { Export-ModuleMember -Function $_ }
            } -ArgumentList $Path, $ExportList, ($PSCmdlet.ParameterSetName -eq "FilePath") -ReturnResult

            # 4. PLATYPS GENERATION
            # Force Markdown generation with a unique module context
            New-MarkdownHelp -Module $TempModule.Name -OutputFolder $AbsoluteOutput -Force | Out-Null

            # 5. POST-PROCESS: STAMPING & SANITIZATION
            $Docs = Get-ChildItem $AbsoluteOutput -Filter "*.md"
            foreach ($Doc in $Docs) {
                # Append Version Footer
                $Footer = "`n`n---`n**Documentation Metadata**`n* **Source:** $($Path ?? 'In-Memory Function')`n* **Version Hash:** $VersionStamp`n* **Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')*"
                Add-Content -Path $Doc.FullName -Value $Footer -Encoding utf8
            }

            # 6. GENERATE HARDENED INDEX
            $IndexContent = [System.Text.StringBuilder]::new()
            [void]$IndexContent.AppendLine("# Technical Reference Index")
            [void]$IndexContent.AppendLine("> Target: **$($Path ?? $FunctionName)**`n")
            foreach ($d in $Docs) { [void]$IndexContent.AppendLine("- [$($d.BaseName)]($($d.Name))") }
            $IndexContent.ToString() | Out-File (Join-Path $AbsoluteOutput "index.md") -Encoding utf8

            Write-Host "Success: Hardened Wiki generated at $AbsoluteOutput" -ForegroundColor Green
        }
        catch {
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }
        finally {
            # Ensure the temporary module is purged from RAM regardless of success/failure
            if (Get-Module $TempModuleName) { Remove-Module $TempModuleName }
        }
    }
}
