# validate-scan-config.ps1 — validate scan-config.yaml against its JSON schema
# Stage: pre-commit | Runs only when scan-config.yaml is staged.
param([Parameter(ValueFromRemainingArguments)]$ExtraArgs)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"
$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path

# Only run when the config itself changed.
$staged = git diff --cached --name-only --diff-filter=ACMR 2>$null
if (-not ($staged | Where-Object { $_ -match 'scan-config\.yaml$' })) {
    Write-HookLog "PASS: scan-config.yaml not staged"
    exit 0
}

$py = Find-WorkingPython
if (-not $py) {
    Write-HookWarn "python not found on PATH - allowing commit (fail-open)"
    exit 0
}

Start-ScanTimer
Write-HookLog "Validating scan-config.yaml against schema..."

$output = & $py (Join-Path $RepoRoot 'scripts/validate-scan-config.py') 'scan-config.yaml' 2>&1
$exitCode = $LASTEXITCODE
$durationMs = Stop-ScanTimer

$output | ForEach-Object { Write-Host $_ }

if ($exitCode -eq 0) {
    Write-HookLog "PASS (${durationMs}ms)"
    exit 0
} else {
    Write-HookLog "FAIL: scan-config.yaml does not conform to schemas/scan-config.schema.json"
    exit 1
}
