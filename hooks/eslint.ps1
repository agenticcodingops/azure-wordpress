# eslint.ps1 — ESLint for staged TS/JS (auto-fix + gate on remaining errors)
# Stage: pre-commit | Mode: staged ts/tsx/js/jsx only
#
# Working dir comes from scan-config.yaml (languages.typescript.build.working_dir).
param([Parameter(ValueFromRemainingArguments)]$ExtraArgs)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"

# An incomplete scan blocks. With the explicit local opt-in it warns and returns.
function Confirm-IncompleteScan {
    param([string]$Reason, [string]$Remedy)
    if ($env:SCAN_ALLOW_TOOL_ERRORS -eq '1') {
        Write-HookWarn "eslint: $Reason; scan incomplete, explicit local fail-open opt-in (SCAN_ALLOW_TOOL_ERRORS=1)"
        return
    }
    Write-HookError "eslint: $Reason; scan incomplete. $Remedy"
    exit 1
}

# Return 'inside', 'outside', or nothing for a missing directory: see lib/working_dir.py.
function Get-WorkingDirState {
    param([string[]]$Paths)
    $config = if ($env:SCAN_CONFIG_FILE) { $env:SCAN_CONFIG_FILE } else { 'scan-config.yaml' }
    $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $python = Find-WorkingPython
    # The leading NUL separates any preamble that Windows PowerShell writes to the pipe.
    "`0$($Paths -join "`0")`0" | & $python -B -E -P "$PSScriptRoot/lib/working_dir.py" $config
}

$allTs = Get-StagedFiles -Extensions @('ts', 'tsx', 'js', 'jsx')
if (@($allTs).Count -eq 0) {
    Write-HookLog "PASS: No TS/JS files staged"
    exit 0
}

$workingDir = Read-ScanConfigValue -Key 'languages.typescript.build.working_dir' -Default '.'
# An empty/whitespace working_dir would make $wdPrefix='/' and match no staged file
# => false PASS. Coerce back to repo-root before the prefix is built.
if ([string]::IsNullOrWhiteSpace($workingDir)) { $workingDir = '.' }
$wdPrefix = ($workingDir.TrimEnd('/', '\') + '/')
$missingDir = "working_dir '$workingDir' is not an existing directory"
$fixDir = 'Fix languages.typescript.build.working_dir in scan-config.yaml.'

# Check before the prefix filter, which would report a missing directory as a PASS.
$dirState = $null
if ($workingDir -ne '.') {
    $dirState = Get-WorkingDirState -Paths $allTs
    # PowerShell also accepts spellings that Python does not, as the Bash twin's -d does.
    if (-not $dirState -and -not (Test-Path -LiteralPath $workingDir -PathType Container)) {
        Confirm-IncompleteScan $missingDir $fixDir
    }
}

$files = @()
foreach ($f in $allTs) {
    $norm = $f -replace '\\', '/'
    if ($workingDir -eq '.') { $files += $norm }
    elseif ($norm.StartsWith($wdPrefix)) { $files += $norm.Substring($wdPrefix.Length) }
}
if ($files.Count -eq 0) {
    if ($dirState -eq 'inside') {
        Write-HookWarn "eslint: nothing under working_dir '$workingDir' was selected, so nothing was linted. Write the value exactly as Git spells the directory, or '.' for the repository root."
    } else {
        Write-HookLog "PASS: No staged TS/JS under '$workingDir'"
    }
    exit 0
}

# Resolve an eslint runner; finding none is an incomplete scan. Resolve the
# working dir to an ABSOLUTE path so the local-bin path survives Push-Location below
# (a relative path would double, e.g. mobile/mobile/node_modules/...), and check the
# POSIX binary too so macOS/Linux find the local install.
$workingDirPath = (Resolve-Path -LiteralPath $workingDir -ErrorAction SilentlyContinue).Path
if (-not $workingDirPath) { $workingDirPath = $workingDir }
# Repository binaries and executable configs require explicit trust.
$trustedConfig = $null
if ($env:SCAN_TRUST_REPO_CODE -eq '1') {
$localBinCmd = Join-Path $workingDirPath 'node_modules/.bin/eslint.cmd'   # Windows
$localBinPosix = Join-Path $workingDirPath 'node_modules/.bin/eslint'     # macOS/Linux
$runner = $null; $runnerArgs = @()
if (Test-Path $localBinCmd) { $runner = $localBinCmd }
elseif (Test-Path $localBinPosix) { $runner = $localBinPosix }
elseif (Get-Command eslint -ErrorAction SilentlyContinue) { $runner = 'eslint' }
elseif (Get-Command npx -ErrorAction SilentlyContinue) { $runner = 'npx'; $runnerArgs = @('--no-install', 'eslint') }
else {
    Confirm-IncompleteScan "no eslint runner found (node_modules/.bin/eslint, eslint on PATH, or npx)" `
        "Provision the eslint runner: install it in '$workingDir' (node_modules) or put it on PATH."
    exit 0
}

} else {
    $runner, $trustedConfig = Get-TrustedAppTool 'eslint'
    $runnerArgs = @()
}

Start-ScanTimer
Write-HookLog "Linting... ($($files.Count) TS/JS files in $workingDir)"

$eslintArgs = $runnerArgs + @('--fix')
if ($env:SCAN_TRUST_REPO_CODE -ne '1') {
    if ($ExtraArgs) { throw 'Extra arguments require SCAN_TRUST_REPO_CODE=1' }
    $eslintArgs += @('--config', $trustedConfig, '--no-config-lookup')
}
foreach ($file in $files) { Assert-SafeWritePath (Join-Path $workingDirPath $file) }
if ($ExtraArgs) { $eslintArgs += $ExtraArgs }
$eslintArgs += '--'
$eslintArgs += $files

# Guard Push-Location: selected files need the directory exactly as configured. With
# the opt-in, skip here, after the trusted-tool checks above, which still block.
if (-not (Test-Path -LiteralPath $workingDirPath -PathType Container)) {
    Confirm-IncompleteScan $missingDir $fixDir
    exit 0
}

Push-Location -LiteralPath $workingDirPath
try {
    $output = & $runner @eslintArgs 2>&1
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
}
$durationMs = Stop-ScanTimer

if ($exitCode -eq 0) {
    Write-HookLog "PASS: ESLint clean (${durationMs}ms)"
    Write-ScanJson (Build-PassJson -Tool 'eslint' -ScanDirectory $workingDir -DurationMs $durationMs)
    exit 0
} elseif ($exitCode -eq 1) {
    $output | ForEach-Object { Write-Host $_ }
    Write-HookLog "FAIL: ESLint errors remain (some may have been auto-fixed; re-stage)"
    Write-ScanJson (Build-FindingsJson -Tool 'eslint' -ScanDirectory $workingDir -DurationMs $durationMs -High 1)
    exit 1
} else {
    $null = Get-HookExitCode -ToolExitCode $exitCode
    exit 0
}
