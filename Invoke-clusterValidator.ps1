<#
.SYNOPSIS
    Targeted Validation for 4-node / 5-instance SQL Cluster (DGDSQL60C).
    Verifies storage delivery, MPIO status, and SCSI-3 reservations.
#>

$Nodes = "dgddbsw0335", "dgddbsw0336", "dgddbsw0337", "dgddbsw0338" # Ensure these match your 4 node names
$ReportPath = "C:\Temp\ClusterValidation_$(Get-Date -Format 'yyyyMMdd_HHmm').html"

Write-Host "--- Starting Targeted Cluster Validation ---" -ForegroundColor Cyan

# 1. Pre-Flight: Check if MPIO is claimed on the local node
$MPIOClaim = Get-MSDSMGlobalDefaultLoadBalancePolicy
if ($null -eq $MPIOClaim) {
    Write-Warning "MPIO is not showing a global claim. Storage validation may report multiple paths as separate disks."
}

# 2. Storage Inventory Check (Ensures all 32 disks are visible)
Write-Host "Verifying disk count across nodes..." -ForegroundColor Yellow
foreach ($Node in $Nodes) {
    Invoke-Command -ComputerName $Node -ScriptBlock {
        $Count = (Get-Disk | Where-Object Number -ne 0).Count
        Write-Host "Node $env:COMPUTERNAME sees $Count disks."
    }
}

# 3. Execution of the Official Microsoft Cluster Validation
# We exclude 'Storage Spaces Direct' because you are on a traditional SAN/VMware setup.
Write-Host "Running Test-Cluster. This may take several minutes due to 32 disks..." -ForegroundColor Cyan

Test-Cluster -Node $Nodes `
             -Include "Inventory", "Network", "System Configuration", "Storage" `
             -Exclude "Storage Spaces Direct" `
             -ReportPath $ReportPath

Write-Host "--- Validation Complete ---" -ForegroundColor Green
Write-Host "Report saved to: $ReportPath" -ForegroundColor White
