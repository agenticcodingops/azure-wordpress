# prettier.ps1 — Prettier formatting for staged TS/JS/CSS/JSON/MD
# Stage: pre-commit | Mode: staged files only
#
# Runs --write (auto-format). Under Lefthook use stage_fixed:true to re-stage.
# Working dir comes from scan-config.yaml (languages.typescript.build.working_dir).
param([Parameter(ValueFromRemainingArguments)]$ExtraArgs)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"

$allFiles = Get-StagedFiles -Extensions @('ts', 'tsx', 'js', 'jsx', 'json', 'css', 'scss', 'md')
if (@($allFiles).Count -eq 0) {
    Write-HookLog "PASS: No formattable files staged"
    exit 0
}

$workingDir = Read-ScanConfigValue -Key 'languages.typescript.build.working_dir' -Default '.'
$wdPrefix = ($workingDir.TrimEnd('/', '\') + '/')

$files = @()
foreach ($f in $allFiles) {
    $norm = $f -replace '\\', '/'
    if ($workingDir -eq '.') { $files += $norm }
    elseif ($norm.StartsWith($wdPrefix)) { $files += $norm.Substring($wdPrefix.Length) }
}
if ($files.Count -eq 0) {
    Write-HookLog "PASS: No staged files under '$workingDir'"
    exit 0
}

# Resolve the working dir to an ABSOLUTE path so the local-bin path survives
# Push-Location below (a relative path would double, e.g. mobile/mobile/node_modules/...),
# and check the POSIX binary too so macOS/Linux find the local install.
$workingDirPath = (Resolve-Path -LiteralPath $workingDir -ErrorAction SilentlyContinue).Path
if (-not $workingDirPath) { $workingDirPath = $workingDir }
$localBinCmd = Join-Path $workingDirPath 'node_modules/.bin/prettier.cmd'   # Windows
$localBinPosix = Join-Path $workingDirPath 'node_modules/.bin/prettier'     # macOS/Linux
$runner = $null; $runnerArgs = @()
if (Test-Path $localBinCmd) { $runner = $localBinCmd }
elseif (Test-Path $localBinPosix) { $runner = $localBinPosix }
elseif (Get-Command prettier -ErrorAction SilentlyContinue) { $runner = 'prettier' }
elseif (Get-Command npx -ErrorAction SilentlyContinue) { $runner = 'npx'; $runnerArgs = @('--no-install', 'prettier') }
else {
    Write-HookWarn "prettier not found - allowing commit (fail-open)"
    exit 0
}

Start-ScanTimer
Write-HookLog "Formatting... ($($files.Count) files in $workingDir)"

$prettierArgs = $runnerArgs + @('--write', '--ignore-unknown')
if ($ExtraArgs) { $prettierArgs += $ExtraArgs }
$prettierArgs += $files

# Guard Push-Location: under $ErrorActionPreference='Stop' a missing dir throws.
# Fail-open (skip) if the working dir is gone.
if (-not (Test-Path -LiteralPath $workingDirPath -PathType Container)) {
    Write-HookWarn "working dir '$workingDirPath' not found - allowing commit (fail-open)"
    exit 0
}

Push-Location -LiteralPath $workingDirPath
try {
    $output = & $runner @prettierArgs 2>&1
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
}
$durationMs = Stop-ScanTimer

if ($exitCode -eq 0) {
    Write-HookLog "PASS: Prettier formatted (${durationMs}ms)"
    Write-ScanJson (Build-PassJson -Tool 'prettier' -ScanDirectory $workingDir -DurationMs $durationMs)
    exit 0
} else {
    $output | ForEach-Object { Write-Host $_ }
    Write-HookLog "FAIL: Prettier error (syntax?)"
    Write-ScanJson (Build-FindingsJson -Tool 'prettier' -ScanDirectory $workingDir -DurationMs $durationMs -Medium 1)
    exit 1
}
