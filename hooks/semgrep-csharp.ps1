# semgrep-csharp.ps1 — Semgrep SAST for C# (p/csharp ruleset)
# Stage: pre-commit | Mode: scan ONLY staged .cs files | native Windows, no WSL
param([Parameter(ValueFromRemainingArguments)]$ExtraArgs)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"

if (-not (Test-ToolAvailable 'semgrep')) { exit 0 }

# Native Windows path (Fall-2025) + UTF-8 so Semgrep runs without WSL.
$env:PYTHONUTF8 = '1'
$env:SEMGREP_SEND_METRICS = 'off'

$files = Get-StagedFiles -Extensions @('cs')
if (@($files).Count -eq 0) {
    Write-HookLog "PASS: No C# files staged"
    exit 0
}

$ruleset = if ($env:SEMGREP_RULESET_CSHARP) { $env:SEMGREP_RULESET_CSHARP } else { 'p/csharp' }

Start-ScanTimer
Write-HookLog "Scanning... ($(@($files).Count) C# files, $ruleset)"

# Single --json run -> accurate per-severity counts (parsed natively).
$tmpJson = New-TemporaryFile
$semgrepArgs = @('scan', '--config', $ruleset, '--metrics', 'off', '--json', '--output', $tmpJson)
if ($ExtraArgs) { $semgrepArgs += $ExtraArgs }
$semgrepArgs += $files

& semgrep @semgrepArgs *> $null
$sgExit = $LASTEXITCODE
$durationMs = Stop-ScanTimer

try {
    if ($sgExit -ne 0 -and ((Get-Item $tmpJson).Length -eq 0)) {
        $null = Get-HookExitCode -ToolExitCode $sgExit
        Write-HookLog "PASS: scanner error, allowing commit (fail-open)"
        Write-ScanJson (Build-PassJson -Tool 'semgrep-csharp' -DurationMs $durationMs)
        exit 0
    }
    $counts = Get-SemgrepCounts -JsonPath $tmpJson
    if ($counts.Total -eq 0) {
        Write-HookLog "PASS: No findings (${durationMs}ms)"
        Write-ScanJson (Build-PassJson -Tool 'semgrep-csharp' -DurationMs $durationMs)
        exit 0
    } else {
        Show-SemgrepFindings -JsonPath $tmpJson
        Write-HookLog "FAIL: $(Format-FindingSummary -High $counts.High -Medium $counts.Medium -Low $counts.Low)"
        Write-ScanJson (Build-FindingsJson -Tool 'semgrep-csharp' -DurationMs $durationMs -High $counts.High -Medium $counts.Medium -Low $counts.Low)
        exit 1
    }
} finally {
    Remove-Item $tmpJson -ErrorAction SilentlyContinue
}
