# checkov.ps1 — Checkov Terraform policy scan
# Stage: pre-push | Severity: per config (blocklist approach)
param([Parameter(ValueFromRemainingArguments)]$ExtraArgs)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"

Invoke-PushSnapshot -HookPath $PSCommandPath -HookArguments $ExtraArgs

# Verify tool availability
$scanner = Test-ToolAvailable 'checkov'
if (-not $scanner) { exit 0 }

Start-ScanTimer

# Detect scan directories
$scanDirs = Get-ChangedDirs
if (-not $scanDirs -or $scanDirs.Count -eq 0) {
    Write-HookLog "PASS: No Terraform files selected"
    exit 0
}
$fileCount = Get-TfFileCount -Directories $scanDirs
Write-HookLog "Scanning... ($fileCount files in $($scanDirs.Count) directories)"

$overallExit = 0
$totalCritical = 0
$totalHigh = 0
$totalMedium = 0
$totalLow = 0

$policyFile = New-PassiveCheckovPolicy -ExtraArgs $ExtraArgs
try {
    foreach ($dir in $scanDirs) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }

        # Build Checkov arguments
        $checkovArgs = @('-d', $dir, '--framework', 'terraform', '--output', 'json', '--compact', '--quiet')

        # Run Checkov
        $output = & $scanner @checkovArgs --config-file $policyFile 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 1) {
            # Parse findings
            try {
                $outputText = $output -join "`n"
                $json = $outputText | ConvertFrom-Json
                $failedChecks = $json.results.failed_checks
                if ($failedChecks) {
                    $counts = Get-ScannerSeverityCounts -Findings @($failedChecks) -Tool checkov
                    $totalCritical += $counts.CRITICAL
                    $totalHigh += $counts.HIGH
                    $totalMedium += $counts.MEDIUM
                    $totalLow += $counts.LOW
                }
            } catch {
                $totalCritical += 1
            }
            # Show actionable details so developers know what to fix
            Show-CheckovFindings -JsonOutput ($output -join "`n")
            $overallExit = 1
        } elseif ($exitCode -ne 0) {
            # Any exit but 0 or 1 is a tool error, including crashes and missing codes: blocks unless SCAN_ALLOW_TOOL_ERRORS=1
            $null = Get-HookExitCode -ToolExitCode $exitCode
        }
    }
} finally {
    Remove-Item -LiteralPath $policyFile -Force
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
