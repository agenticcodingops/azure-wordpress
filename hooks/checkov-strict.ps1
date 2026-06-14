# checkov-strict.ps1 — Checkov Terraform strict scan (hard-fail on CRITICAL + HIGH)
# Stage: pre-push | Severity: CRITICAL + HIGH hard-fail
param([Parameter(ValueFromRemainingArguments)]$ExtraArgs)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"

# Verify tool availability
if (-not (Test-ToolAvailable 'checkov')) { exit 0 }

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

    # Build Checkov arguments with hard-fail
    $checkovArgs = @('-d', $dir, '--framework', 'terraform', '--output', 'json', '--compact', '--quiet', '--hard-fail-on', 'CRITICAL,HIGH')

    # Check for config file
    $configFile = Resolve-ScanConfig -Filename '.checkov.yaml'
    if ($configFile) {
        $checkovArgs += @('--config-file', $configFile)
    }

    # Add extra args
    if ($ExtraArgs) {
        $checkovArgs += $ExtraArgs
    }

    # Run Checkov
    $output = & checkov @checkovArgs 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 1) {
        # Parse findings
        try {
            $outputText = $output -join "`n"
            $json = $outputText | ConvertFrom-Json
            $failedChecks = $json.results.failed_checks
            if ($failedChecks) {
                $totalCritical += @($failedChecks | Where-Object { $_.severity -eq 'CRITICAL' }).Count
                $totalHigh += @($failedChecks | Where-Object { $_.severity -eq 'HIGH' }).Count
                $totalMedium += @($failedChecks | Where-Object { $_.severity -eq 'MEDIUM' }).Count
                $totalLow += @($failedChecks | Where-Object { $_.severity -eq 'LOW' -or $null -eq $_.severity }).Count
            }
        } catch {
            $totalCritical += 1
        }
        # Show actionable details so developers know what to fix
        Show-CheckovFindings -JsonOutput ($output -join "`n")
        $overallExit = 1
    } elseif ($exitCode -ge 2) {
        # Infrastructure error — fail-open
        $null = Get-HookExitCode -ToolExitCode $exitCode
    }
}

$durationMs = Stop-ScanTimer

if ($overallExit -eq 0) {
    Write-HookLog "PASS: No findings above threshold"
    Write-ScanJson (Build-PassJson -Tool 'checkov' -DurationMs $durationMs)
} else {
    Write-HookLog "FAIL: $(Format-FindingSummary -Critical $totalCritical -High $totalHigh -Medium $totalMedium -Low $totalLow)"
    Write-ScanJson (Build-FindingsJson -Tool 'checkov' -DurationMs $durationMs -Critical $totalCritical -High $totalHigh -Medium $totalMedium -Low $totalLow)
}

exit $overallExit
