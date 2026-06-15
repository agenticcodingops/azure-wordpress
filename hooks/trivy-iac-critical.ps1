# trivy-iac-critical.ps1 — Trivy IaC scan for CRITICAL misconfigurations only
# Stage: pre-commit | Severity: CRITICAL only | --skip-check-update
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

foreach ($dir in $scanDirs) {
    if (-not (Test-Path $dir -PathType Container)) { continue }

    # Build Trivy arguments as array — safe for paths with spaces/special chars
    $trivyArgs = @('config', $dir, '--severity', 'CRITICAL', '--exit-code', '1', '--format', 'json', '--skip-check-update', '--quiet')

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
            $critical = ($json.Results | ForEach-Object { $_.Misconfigurations } |
                Where-Object { $_.Severity -eq 'CRITICAL' }).Count
            $totalCritical += [int]$critical
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
    Write-HookLog "FAIL: $(Format-FindingSummary -Critical $totalCritical)"
    Write-ScanJson (Build-FindingsJson -Tool 'trivy' -DurationMs $durationMs -Critical $totalCritical)
}

exit $overallExit
