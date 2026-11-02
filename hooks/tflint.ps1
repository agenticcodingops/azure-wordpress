# tflint.ps1 — TFLint Terraform linter
# Stage: pre-push | Severity: per config
param([Parameter(ValueFromRemainingArguments)]$ExtraArgs)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"

Invoke-PushSnapshot -HookPath $PSCommandPath -HookArguments $ExtraArgs

# Verify tool availability
if (-not (Test-ToolAvailable 'tflint')) { exit 0 }

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
$totalHigh = 0
$totalMedium = 0
$totalLow = 0

foreach ($dir in $scanDirs) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }

    # Configuration and plugin cache are provisioned outside the scanned checkout.
    $configFile = $env:SCAN_TFLINT_CONFIG
    if (-not $configFile -or -not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
        throw 'SCAN_TFLINT_CONFIG must name a trusted external config'
    }
    Assert-TrustedTflintConfig $configFile
    $env:TFLINT_PLUGIN_DIR = $env:SCAN_TFLINT_PLUGIN_DIR
    if (-not $env:TFLINT_PLUGIN_DIR) { throw 'Set SCAN_TFLINT_PLUGIN_DIR to an external plugin cache' }
    Assert-ExternalPath $env:TFLINT_PLUGIN_DIR
    if ($ExtraArgs) { throw 'TFLint extra arguments are disabled' }

    # Initialize tflint plugins
    $initArgs = @('--chdir', $dir, '--init')
    if ($configFile) {
        $initArgs += @('--config', $configFile)
    }
    $initExit = 2
    try {
        & tflint @initArgs 2>$null | Out-Null
        $initExit = $LASTEXITCODE
    } catch { $initExit = 2 }
    if ($initExit -ne 0) { throw 'TFLint initialization failed' }

    # Build tflint arguments
    $tflintArgs = @('--chdir', $dir, '--format', 'json')
    if ($configFile) {
        $tflintArgs += @('--config', $configFile)
    }

    # Add extra args
    if ($ExtraArgs) {
        $tflintArgs += $ExtraArgs
    }

    # Run tflint
    $output = & tflint @tflintArgs 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 2) {
        # tflint uses exit 2 for findings
        try {
            $outputText = $output -join "`n"
            $json = $outputText | ConvertFrom-Json
            $issues = $json.issues
            if ($issues) {
                # Severity mapping: error -> HIGH, warning -> MEDIUM, notice -> LOW
                $totalHigh += @($issues | Where-Object { $_.rule.severity -eq 'error' }).Count
                $totalMedium += @($issues | Where-Object { $_.rule.severity -eq 'warning' }).Count
                $totalLow += @($issues | Where-Object { $_.rule.severity -eq 'notice' }).Count
            }
        } catch {
            $totalHigh += 1
        }
        # Show actionable details so developers know what to fix
        Show-TflintFindings -JsonOutput ($output -join "`n")
        $overallExit = 1
    } elseif ($exitCode -ge 3) {
        # Runtime error — fail-open
        $null = Get-HookExitCode -ToolExitCode 2
    } elseif ($exitCode -eq 1) {
        # Config errors — fail-open
        $null = Get-HookExitCode -ToolExitCode 2
    }
}

$durationMs = Stop-ScanTimer

if ($overallExit -eq 0) {
    Write-HookLog "PASS: No findings above threshold"
    Write-ScanJson (Build-PassJson -Tool 'tflint' -DurationMs $durationMs)
} else {
    Write-HookLog "FAIL: $(Format-FindingSummary -High $totalHigh -Medium $totalMedium -Low $totalLow)"
    Write-ScanJson (Build-FindingsJson -Tool 'tflint' -DurationMs $durationMs -High $totalHigh -Medium $totalMedium -Low $totalLow)
}

exit $overallExit
