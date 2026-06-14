# gitleaks.ps1 — Gitleaks secret detection scanner
# Stage: pre-commit | Severity: HIGH (all secrets map to HIGH)
# Uses 'gitleaks protect --staged' to scan ONLY staged changes (not the whole repo)
param([Parameter(ValueFromRemainingArguments)]$ExtraArgs)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"

# Verify tool availability
if (-not (Test-ToolAvailable 'gitleaks')) { exit 0 }

# Check if there are any staged files at all
$stagedFiles = git diff --cached --name-only --diff-filter=ACMR 2>$null
if (-not $stagedFiles -or @($stagedFiles).Count -eq 0) {
    Write-HookLog "PASS: No files staged"
    exit 0
}

Start-ScanTimer

$stagedCount = @($stagedFiles).Count
Write-HookLog "Scanning... ($stagedCount staged files)"

# Build Gitleaks command — 'protect --staged' only scans the staged git diff
$gitleaksArgs = @('protect', '--staged', '--report-format', 'json', '--exit-code', '1')

# Check for config file
$configFile = Resolve-ScanConfig -Filename '.gitleaks.toml'
if ($configFile) {
    $gitleaksArgs += @('--config', $configFile)
}

# Add extra args
if ($ExtraArgs) {
    $gitleaksArgs += $ExtraArgs
}

# Run Gitleaks on staged changes only
$output = & gitleaks @gitleaksArgs 2>&1
$exitCode = $LASTEXITCODE

$totalHigh = 0

if ($exitCode -eq 1) {
    # Parse findings — all Gitleaks findings map to HIGH severity
    try {
        $outputText = $output -join "`n"
        $json = $outputText | ConvertFrom-Json
        $totalHigh = @($json).Count
        # Show actionable details so developers know what to fix
        if ($json) {
            Write-HookLog ""
            foreach ($finding in @($json)) {
                Write-HookLog "  HIGH  $($finding.RuleID)  $($finding.File):$($finding.StartLine)-$($finding.EndLine)"
                Write-HookLog "    $($finding.Description)"
                # Do NOT print $finding.Match — it is the raw secret value. Location
                # (file:line) + rule is enough to find and fix it without leaking it to logs.
            }
            Write-HookLog ""
        }
    } catch {
        $totalHigh = 1
    }
} elseif ($exitCode -ge 2) {
    # Infrastructure error — fail-open
    $null = Get-HookExitCode -ToolExitCode $exitCode
    $exitCode = 0
}

$durationMs = Stop-ScanTimer

if ($exitCode -eq 0) {
    Write-HookLog "PASS: No findings above threshold"
    Write-ScanJson (Build-PassJson -Tool 'gitleaks' -DurationMs $durationMs)
} else {
    Write-HookLog "FAIL: $(Format-FindingSummary -High $totalHigh)"
    Write-ScanJson (Build-FindingsJson -Tool 'gitleaks' -DurationMs $durationMs -High $totalHigh)
}

exit $exitCode
