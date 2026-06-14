# sqlfluff.ps1 — SQLFluff linting for staged .sql files
# Stage: pre-commit | Mode: staged .sql only
param([Parameter(ValueFromRemainingArguments)]$ExtraArgs)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"

if (-not (Test-ToolAvailable 'sqlfluff')) { exit 0 }

$files = Get-StagedFiles -Extensions @('sql')
if (@($files).Count -eq 0) {
    Write-HookLog "PASS: No SQL files staged"
    exit 0
}

# Respect a project .sqlfluff config (a CLI --dialect would OVERRIDE it); only force a
# default dialect when no config is present.
$sqlfluffArgs = @('lint')
$dialectNote = 'from .sqlfluff'
if (-not (Test-Path '.sqlfluff')) {
    $sqlfluffArgs += @('--dialect', 'ansi')
    $dialectNote = 'ansi (default; no .sqlfluff)'
}

Start-ScanTimer
Write-HookLog "Linting... ($(@($files).Count) SQL files, dialect=$dialectNote)"
if ($ExtraArgs) { $sqlfluffArgs += $ExtraArgs }
$sqlfluffArgs += $files

$output = & sqlfluff @sqlfluffArgs 2>&1
$exitCode = $LASTEXITCODE
$durationMs = Stop-ScanTimer

if ($exitCode -eq 0) {
    Write-HookLog "PASS: SQLFluff clean (${durationMs}ms)"
    Write-ScanJson (Build-PassJson -Tool 'sqlfluff' -DurationMs $durationMs)
    exit 0
} elseif ($exitCode -eq 1) {
    $output | ForEach-Object { Write-Host $_ }
    Write-HookLog "FAIL: SQLFluff lint issues"
    Write-ScanJson (Build-FindingsJson -Tool 'sqlfluff' -DurationMs $durationMs -Medium 1)
    exit 1
} else {
    $null = Get-HookExitCode -ToolExitCode $exitCode
    exit 0
}
