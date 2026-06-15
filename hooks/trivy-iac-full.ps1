# trivy-iac-full.ps1 — Trivy IaC full scan for all severities
# Stage: pre-push | Severity: All | --skip-check-update
param([Parameter(ValueFromRemainingArguments)]$ExtraArgs)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"

# Verify tool availability
if (-not (Test-ToolAvailable 'trivy')) { exit 0 }

Start-ScanTimer

# Detect scan directories
$scanDirs = Get-ChangedDirs
if (-not $scanDirs -or $scanDirs.Count -eq 0) {
    Write-HookLog "PASS: No Terraform files staged"
    exit 0
}
$fileCount = Get-TfFileCount -Directories $scanDirs
Write-HookLog "Scanning... ($fileCount files in $($scanDirs.Count) directories)"

$overallExit = 0
$totalCritical = 0
$totalHigh = 0
$totalMedium = 0
$totalLow = 0

foreach ($dir in $scanDirs) {
    if (-not (Test-Path $dir -PathType Container)) { continue }

    # Build Trivy arguments as array — safe for paths with spaces/special chars
    $trivyArgs = @('config', $dir, '--severity', 'CRITICAL,HIGH,MEDIUM,LOW', '--exit-code', '1', '--format', 'json', '--skip-check-update', '--quiet')

    # Check for config file
    $configFile = Resolve-ScanConfig -Filename '.trivyignore'
    if ($configFile) {
        $trivyArgs += @('--ignorefile', $configFile)
    }

    # Add extra args
    if ($ExtraArgs) {
        $trivyArgs += $ExtraArgs
    }

    # Run Trivy with retry
    $result = Invoke-TrivyWithRetry -ArgumentList $trivyArgs

    if ($result.ExitCode -eq 1) {
        # Parse findings
        try {
            $json = $result.Output | ConvertFrom-Json
            $misconfigs = $json.Results | ForEach-Object { $_.Misconfigurations } | Where-Object { $_ }
            $totalCritical += @($misconfigs | Where-Object { $_.Severity -eq 'CRITICAL' }).Count
            $totalHigh += @($misconfigs | Where-Object { $_.Severity -eq 'HIGH' }).Count
            $totalMedium += @($misconfigs | Where-Object { $_.Severity -eq 'MEDIUM' }).Count
            $totalLow += @($misconfigs | Where-Object { $_.Severity -eq 'LOW' }).Count
        } catch {
            $totalCritical += 1
        }
        # Show actionable details so developers know what to fix
        Show-TrivyIacFindings -JsonOutput $result.Output
        $overallExit = 1
    } elseif ($result.ExitCode -ge 2) {
        # Infrastructure error — fail-open
        $null = Get-HookExitCode -ToolExitCode $result.ExitCode
    }
}

$durationMs = Stop-ScanTimer

if ($overallExit -eq 0) {
    Write-HookLog "PASS: No findings above threshold"
    Write-ScanJson (Build-PassJson -Tool 'trivy' -DurationMs $durationMs)
} else {
    Write-HookLog "FAIL: $(Format-FindingSummary -Critical $totalCritical -High $totalHigh -Medium $totalMedium -Low $totalLow)"
    Write-ScanJson (Build-FindingsJson -Tool 'trivy' -DurationMs $durationMs -Critical $totalCritical -High $totalHigh -Medium $totalMedium -Low $totalLow)
}

exit $overallExit
