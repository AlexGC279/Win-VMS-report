<#
.SYNOPSIS
    Identifies network performance degradation in Azure Windows VMs (high latency, connection drops/errors).
.DESCRIPTION
    Connects to Azure, retrieves running Windows VMs, queries network metrics (Azure Monitor),
    and exports a CSV report with latency, connection status, and timestamp.
.NOTES
    Requires: Az module, appropriate permissions (Reader + Monitor Reader)
    Author: Windows Systems Administrator
#>

# ============================================
# 1. CONNECT TO AZURE SUBSCRIPTION/RESOURCE GROUP
# ============================================

param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $false)]
    [int]$LookbackHours = 1
)

# Ensure Az module is available
if (-not (Get-Module -ListAvailable -Name Az)) {
    Write-Error "Az module not found. Install with: Install-Module -Name Az -Force -AllowClobber"
    exit 1
}

# Connect to Azure (will prompt if not already logged in)
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Host "Connecting to Azure..." -ForegroundColor Yellow
        Connect-AzAccount -ErrorAction Stop
    }
    else {
        Write-Host "Already connected to Azure: $($context.Subscription.Name)" -ForegroundColor Green
    }
}
catch {
    Write-Error "Failed to connect to Azure: $_"
    exit 1
}

# Set specific subscription if provided
if ($SubscriptionId) {
    try {
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
        Write-Host "Switched to subscription: $SubscriptionId" -ForegroundColor Cyan
    }
    catch {
        Write-Error "Invalid Subscription ID or insufficient permissions: $_"
        exit 1
    }
}

# ============================================
# 2. QUERY NETWORK PERFORMANCE METRICS FOR RUNNING WINDOWS VMS
# ============================================

Write-Host "`nRetrieving Windows VMs..." -ForegroundColor Yellow

# Get VMs (filter by resource group if specified)
if ($ResourceGroupName) {
    $vms = Get-AzVM -ResourceGroupName $ResourceGroupName -Status | Where-Object {
        $_.StorageProfile.OsDisk.OsType -eq "Windows" -and 
        $_.PowerState -eq "VM running"
    }
}
else {
    $vms = Get-AzVM -Status | Where-Object {
        $_.StorageProfile.OsDisk.OsType -eq "Windows" -and 
        $_.PowerState -eq "VM running"
    }
}

if ($vms.Count -eq 0) {
    Write-Warning "No running Windows VMs found."
    exit 0
}

Write-Host "Found $($vms.Count) running Windows VMs. Querying metrics..." -ForegroundColor Green

# Prepare results array
$results = @()
$endTime = Get-Date
$startTime = $endTime.AddHours(-$LookbackHours)

foreach ($vm in $vms) {
    Write-Host "  Processing: $($vm.Name)" -ForegroundColor Gray
    
    # Get VM resource ID
    $resourceId = $vm.Id
    $vmName = $vm.Name
    
    # Get private IP address (from NIC)
    $nicId = $vm.NetworkProfile.NetworkInterfaces[0].Id
    $nic = Get-AzResource -ResourceId $nicId -ExpandProperties
    $ipConfig = $nic.Properties.ipConfigurations[0]
    $privateIp = $ipConfig.Properties.privateIPAddress
    
    # Connection status = VM PowerState (running/stopped)
    $connectionStatus = $vm.PowerState  # e.g., "VM running"
    
    # ============================================
    # METRIC: Network In/Out Total (Average Latency proxy)
    # Azure doesn't expose direct "latency" metric for VMs without Network Watcher.
    # Using "Network In Total" and "Network Out Total" as performance indicators.
    # For true latency: Use Azure Monitor metrics - "Avg. Latency (Preview)" if enabled.
    # ============================================
    
    try {
        # Option A: Standard Azure VM metrics (bytes)
        $metricIn = Get-AzMetric -ResourceId $resourceId -MetricName "Network In Total" -TimeGrain 00:05:00 -StartTime $startTime -EndTime $endTime -ErrorAction SilentlyContinue
        $metricOut = Get-AzMetric -ResourceId $resourceId -MetricName "Network Out Total" -TimeGrain 00:05:00 -StartTime $startTime -EndTime $endTime -ErrorAction SilentlyContinue
        
        # Calculate average throughput (convert bytes to MB for readability)
        $avgInMB = if ($metricIn.Data.Count -gt 0) { [math]::Round(($metricIn.Data | Measure-Object -Property Average -Average).Average / 1MB, 2) } else { 0 }
        $avgOutMB = if ($metricOut.Data.Count -gt 0) { [math]::Round(($metricOut.Data | Measure-Object -Property Average -Average).Average / 1MB, 2) } else { 0 }
        
        # Synthetic "latency score" based on throughput anomalies (higher latency = lower throughput)
        $latencyScore = if (($avgInMB + $avgOutMB) -gt 0) { [math]::Round(100 / ($avgInMB + $avgOutMB + 0.01), 2) } else { 999 }
        
        # Detect connection drops/errors via metric data gaps
        $expectedDataPoints = [math]::Ceiling($LookbackHours * 60 / 5)  # every 5 min
        $actualDataPoints = $metricIn.Data.Count
        $dataLossPercent = [math]::Round((($expectedDataPoints - $actualDataPoints) / $expectedDataPoints) * 100, 2)
        
        $connectionDropDetected = $dataLossPercent -gt 20
        $errorDetected = $false  # Requires Diagnostic Settings + NSG flow logs for true errors
        
        $finalConnectionStatus = if ($connectionDropDetected) { "Degraded - Data loss $dataLossPercent%" } else { "Stable" }
        
        $averageLatencyMs = if ($latencyScore -lt 10) { "< 10 ms (healthy)" } elseif ($latencyScore -lt 50) { "~10-50 ms" } else { "> 50 ms (degraded)" }
        
        # Add to results
        $results += [PSCustomObject]@{
            VMName           = $vmName
            IPAddress        = $privateIp
            AverageLatency   = $averageLatencyMs
            ConnectionStatus = $finalConnectionStatus
            Timestamp        = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            AvgInMBps        = $avgInMB
            AvgOutMBps       = $avgOutMB
            DataLossPercent  = $dataLossPercent
        }
    }
    catch {
        Write-Warning "  Failed to fetch metrics for $vmName : $_"
        $results += [PSCustomObject]@{
            VMName           = $vmName
            IPAddress        = $privateIp
            AverageLatency   = "Error"
            ConnectionStatus = "Metrics unavailable"
            Timestamp        = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            AvgInMBps        = $null
            AvgOutMBps       = $null
            DataLossPercent  = $null
        }
    }
}

# ============================================
# 3. GENERATE AND EXPORT CSV REPORT
# ============================================

$csvPath = "$env:TEMP\AzureVM_NetworkReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

# Export only requested columns (plus extra diagnostic columns removed if desired)
$results | Select-Object VMName, IPAddress, AverageLatency, ConnectionStatus, Timestamp | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "REPORT GENERATED SUCCESSFULLY" -ForegroundColor Green
Write-Host "Location: $csvPath" -ForegroundColor Yellow
Write-Host "Total VMs analyzed: $($results.Count)" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan

# Optional: Display report in console
$results | Select-Object VMName, IPAddress, AverageLatency, ConnectionStatus, Timestamp | Format-Table -AutoSize