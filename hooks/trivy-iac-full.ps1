# trivy-iac-full.ps1 — Trivy IaC full scan for all severities
# Stage: pre-push | Severity: All | --skip-check-update
param([Parameter(ValueFromRemainingArguments)]$ExtraArgs)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"

Invoke-PushSnapshot -HookPath $PSCommandPath -HookArguments $ExtraArgs

# Verify tool availability
$scanner = Test-ToolAvailable 'trivy'
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

foreach ($dir in $scanDirs) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }

    # Build Trivy arguments as array — safe for paths with spaces/special chars
    $trivyArgs = @('config', '--severity', 'CRITICAL,HIGH,MEDIUM,LOW', '--exit-code', '1', '--format', 'json', '--skip-check-update', '--quiet')

    # Check for config file
    $configFile = Resolve-ScanConfig -Filename '.trivyignore'
    if ($configFile) {
        $trivyArgs += @('--ignorefile', $configFile)
    }

    # Add extra args
    if ($ExtraArgs) {
        $trivyArgs += $ExtraArgs
    }

$trivyArgs += @('--', $dir)

    # Run Trivy with retry
    $result = Invoke-TrivyWithRetry -ToolPath $scanner -ArgumentList $trivyArgs

    if ($result.ExitCode -eq 1) {
        # Parse findings
        try {
            $json = $result.Output | ConvertFrom-Json
            $misconfigs = $json.Results | ForEach-Object { $_.Misconfigurations } | Where-Object { $_ }
            $counts = Get-ScannerSeverityCounts -Findings @($misconfigs) -Tool trivy
            $totalCritical += $counts.CRITICAL
            $totalHigh += $counts.HIGH
            $totalMedium += $counts.MEDIUM
            $totalLow += $counts.LOW
        } catch {
            $totalCritical += 1
        }
        # Show actionable details so developers know what to fix
        Show-TrivyIacFindings -JsonOutput $result.Output
        $overallExit = 1
    } elseif ($result.ExitCode -ne 0) {
        # Any exit but 0 or 1 is a tool error, including crashes and missing codes: blocks unless SCAN_ALLOW_TOOL_ERRORS=1
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
