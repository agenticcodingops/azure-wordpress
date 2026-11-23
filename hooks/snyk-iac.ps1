# snyk-iac.ps1 — Snyk IaC scan for Terraform misconfigurations
# Stage: pre-push | Severity: all | Optional: blocks if not installed, skips if not authenticated
param([Parameter(ValueFromRemainingArguments)]$ExtraArgs)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"

Invoke-PushSnapshot -HookPath $PSCommandPath -HookArguments $ExtraArgs

# Verify tool availability (a missing CLI blocks unless SCAN_ALLOW_TOOL_ERRORS=1)
$scanner = Test-ToolAvailable 'snyk'
if (-not $scanner) { exit 0 }

# Deliberate skip: no SNYK_TOKEN and no login. An invalid token is not skipped; its scan error blocks.
if (-not $env:SNYK_TOKEN) {
    try {
        $null = & $scanner whoami 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-HookWarn "Snyk not authenticated (no SNYK_TOKEN and 'snyk whoami' failed) - allowing push (fail-open)"
            exit 0
        }
    } catch {
        Write-HookWarn "Snyk authentication check failed - allowing push (fail-open)"
        exit 0
    }
}

Start-ScanTimer

# Detect Terraform directories in the selected object tree.
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

    # Build Snyk arguments
    $snykArgs = @('iac', 'test', '--json')

    # Check for .snyk policy file
    if (Test-Path '.snyk') {
        $snykArgs += @('--policy-path', (Get-Location).Path)
    }

    # Add extra args
    if ($ExtraArgs) {
        $snykArgs += $ExtraArgs
    }

    # Run Snyk
    Push-Location -LiteralPath $dir
    try {
        $output = & $scanner @snykArgs 2>&1
        $exitCode = $LASTEXITCODE
    } finally { Pop-Location }

    if ($exitCode -eq 1) {
        # Parse findings
        try {
            $outputText = $output -join "`n"
            $json = $outputText | ConvertFrom-Json
            $issues = $json.infrastructureAsCodeIssues
            if ($issues) {
                $counts = Get-ScannerSeverityCounts -Findings @($issues) -Tool snyk
                $totalCritical += $counts.CRITICAL
                $totalHigh += $counts.HIGH
                $totalMedium += $counts.MEDIUM
                $totalLow += $counts.LOW

                # Show actionable details (file/severity/title) so developers know
                # what to fix before the hook blocks the push.
                $topTargetFile = $json.targetFile
                Write-HookLog ""
                foreach ($issue in @($issues | Sort-Object @{Expression = {
                                switch ($_.severity) { 'critical' { 0 } 'high' { 1 } 'medium' { 2 } default { 3 } }
                            }
                        })) {
                    # Prefer the issue's own file/path (more precise); fall back to the
                    # project-level targetFile only when the per-issue value is absent.
                    $file = $issue.targetFile
                    if ([string]::IsNullOrWhiteSpace($file)) {
                        $issuePath = $issue.path
                        if ($issuePath) { $file = ($issuePath -join '.') }
                    }
                    if ([string]::IsNullOrWhiteSpace($file)) { $file = $topTargetFile }
                    $loc = if ($issue.lineNumber) { "$($file):$($issue.lineNumber)" } else { $file }
                    Write-HookLog "  $(Get-ScannerSeverity -Severity $issue.severity -Tool snyk)  $($issue.id)  $loc"
                    Write-HookLog "    $($issue.title)"
                }
                Write-HookLog ""
            }
        } catch {
            $totalHigh += 1
        }
        $overallExit = 1
    } elseif ($exitCode -ne 0) {
        # Any exit but 0 or 1 is a tool error, including crashes and missing codes: blocks unless SCAN_ALLOW_TOOL_ERRORS=1
        $null = Get-HookExitCode -ToolExitCode $exitCode
    }
}

$durationMs = Stop-ScanTimer

if ($overallExit -eq 0) {
    Write-HookLog "PASS: No findings above threshold"
    Write-ScanJson (Build-PassJson -Tool 'snyk' -DurationMs $durationMs)
} else {
    Write-HookLog "FAIL: $(Format-FindingSummary -Critical $totalCritical -High $totalHigh -Medium $totalMedium -Low $totalLow)"
    Write-ScanJson (Build-FindingsJson -Tool 'snyk' -DurationMs $durationMs -Critical $totalCritical -High $totalHigh -Medium $totalMedium -Low $totalLow)
}

exit $overallExit
