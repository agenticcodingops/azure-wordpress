# snyk-iac.ps1 — Snyk IaC scan for Terraform misconfigurations
# Stage: pre-push | Severity: all | Optional: fail-open if not installed/authenticated
param([Parameter(ValueFromRemainingArguments)]$ExtraArgs)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"

# Verify tool availability (fail-open if snyk not installed)
if (-not (Test-ToolAvailable 'snyk')) { exit 0 }

# Verify authentication (fail-open if not authenticated)
if (-not $env:SNYK_TOKEN) {
    try {
        $null = & snyk whoami 2>&1
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

# Detect scan directories (only dirs with staged .tf files)
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

    # Build Snyk arguments
    $snykArgs = @('iac', 'test', $dir, '--json')

    # Check for .snyk policy file
    if (Test-Path '.snyk') {
        $snykArgs += @('--policy-path=.')
    }

    # Add extra args
    if ($ExtraArgs) {
        $snykArgs += $ExtraArgs
    }

    # Run Snyk
    $output = & snyk @snykArgs 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 1) {
        # Parse findings
        try {
            $outputText = $output -join "`n"
            $json = $outputText | ConvertFrom-Json
            $issues = $json.infrastructureAsCodeIssues
            if ($issues) {
                $totalCritical += @($issues | Where-Object { $_.severity -eq 'critical' }).Count
                $totalHigh += @($issues | Where-Object { $_.severity -eq 'high' }).Count
                $totalMedium += @($issues | Where-Object { $_.severity -eq 'medium' }).Count
                $totalLow += @($issues | Where-Object { $_.severity -eq 'low' }).Count

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
                    Write-HookLog "  $(($issue.severity).ToUpper())  $($issue.id)  $loc"
                    Write-HookLog "    $($issue.title)"
                }
                Write-HookLog ""
            }
        } catch {
            $totalHigh += 1
        }
        $overallExit = 1
    } elseif ($exitCode -ge 2) {
        # Infrastructure error — fail-open
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
