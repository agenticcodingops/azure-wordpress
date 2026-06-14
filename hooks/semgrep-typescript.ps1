# semgrep-typescript.ps1 — Semgrep SAST for TypeScript/JavaScript (p/typescript)
# Stage: pre-commit | Mode: scan ONLY staged ts/tsx/js/jsx files
param([Parameter(ValueFromRemainingArguments)]$ExtraArgs)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"

if (-not (Test-ToolAvailable 'semgrep')) { exit 0 }

$env:PYTHONUTF8 = '1'
$env:SEMGREP_SEND_METRICS = 'off'

$files = Get-StagedFiles -Extensions @('ts', 'tsx', 'js', 'jsx')
if (@($files).Count -eq 0) {
    Write-HookLog "PASS: No TypeScript/JavaScript files staged"
    exit 0
}

$ruleset = if ($env:SEMGREP_RULESET_TYPESCRIPT) { $env:SEMGREP_RULESET_TYPESCRIPT } else { 'p/typescript' }

Start-ScanTimer
Write-HookLog "Scanning... ($(@($files).Count) TS/JS files, $ruleset)"

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
        Write-ScanJson (Build-PassJson -Tool 'semgrep-typescript' -DurationMs $durationMs)
        exit 0
    }
    $counts = Get-SemgrepCounts -JsonPath $tmpJson
    if ($counts.Total -eq 0) {
        Write-HookLog "PASS: No findings (${durationMs}ms)"
        Write-ScanJson (Build-PassJson -Tool 'semgrep-typescript' -DurationMs $durationMs)
        exit 0
    } else {
        Show-SemgrepFindings -JsonPath $tmpJson
        Write-HookLog "FAIL: $(Format-FindingSummary -High $counts.High -Medium $counts.Medium -Low $counts.Low)"
        Write-ScanJson (Build-FindingsJson -Tool 'semgrep-typescript' -DurationMs $durationMs -High $counts.High -Medium $counts.Medium -Low $counts.Low)
        exit 1
    }
} finally {
    Remove-Item $tmpJson -ErrorAction SilentlyContinue
}
