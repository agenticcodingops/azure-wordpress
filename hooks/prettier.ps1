# prettier.ps1 — Prettier formatting for staged TS/JS/CSS/JSON/MD
# Stage: pre-commit | Mode: staged files only
#
# Runs --write (auto-format). Under Lefthook use stage_fixed:true to re-stage.
# Working dir comes from scan-config.yaml (languages.typescript.build.working_dir).
param([Parameter(ValueFromRemainingArguments)]$ExtraArgs)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"

# An incomplete scan blocks. With the explicit local opt-in it warns and returns.
function Confirm-IncompleteScan {
    param([string]$Reason, [string]$Remedy)
    if ($env:SCAN_ALLOW_TOOL_ERRORS -eq '1') {
        Write-HookWarn "prettier: $Reason; scan incomplete, explicit local fail-open opt-in (SCAN_ALLOW_TOOL_ERRORS=1)"
        return
    }
    Write-HookError "prettier: $Reason; scan incomplete. $Remedy"
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

$allFiles = Get-StagedFiles -Extensions @('ts', 'tsx', 'js', 'jsx', 'json', 'css', 'scss', 'md')
if (@($allFiles).Count -eq 0) {
    Write-HookLog "PASS: No formattable files staged"
    exit 0
}

$workingDir = Read-ScanConfigValue -Key 'languages.typescript.build.working_dir' -Default '.'
$wdPrefix = ($workingDir.TrimEnd('/', '\') + '/')
$missingDir = "working_dir '$workingDir' is not an existing directory"
$fixDir = 'Fix languages.typescript.build.working_dir in scan-config.yaml.'

# Check before the prefix filter, which would report a missing directory as a PASS.
$dirState = $null
if ($workingDir -ne '.') {
    $dirState = Get-WorkingDirState -Paths $allFiles
    # PowerShell also accepts spellings that Python does not, as the Bash twin's -d does.
    if (-not $dirState -and -not (Test-Path -LiteralPath $workingDir -PathType Container)) {
        Confirm-IncompleteScan $missingDir $fixDir
    }
}

$files = @()
foreach ($f in $allFiles) {
    $norm = $f -replace '\\', '/'
    if ($workingDir -eq '.') { $files += $norm }
    elseif ($norm.StartsWith($wdPrefix)) { $files += $norm.Substring($wdPrefix.Length) }
}
if ($files.Count -eq 0) {
    if ($dirState -eq 'inside') {
        Write-HookWarn "prettier: nothing under working_dir '$workingDir' was selected, so nothing was formatted. Write the value exactly as Git spells the directory, or '.' for the repository root."
    } else {
        Write-HookLog "PASS: No staged files under '$workingDir'"
    }
    exit 0
}

# Resolve a runner; finding none is an incomplete scan.
# Resolve the working dir to an ABSOLUTE path so the local-bin path survives
# Push-Location below (a relative path would double, e.g. mobile/mobile/node_modules/...),
# and check the POSIX binary too so macOS/Linux find the local install.
$workingDirPath = (Resolve-Path -LiteralPath $workingDir -ErrorAction SilentlyContinue).Path
if (-not $workingDirPath) { $workingDirPath = $workingDir }
# Repository binaries and executable configs require explicit trust.
$trustedConfig = $null
if ($env:SCAN_TRUST_REPO_CODE -eq '1') {
$localBinCmd = Join-Path $workingDirPath 'node_modules/.bin/prettier.cmd'   # Windows
$localBinPosix = Join-Path $workingDirPath 'node_modules/.bin/prettier'     # macOS/Linux
$runner = $null; $runnerArgs = @()
if (Test-Path $localBinCmd) { $runner = $localBinCmd }
elseif (Test-Path $localBinPosix) { $runner = $localBinPosix }
elseif (Get-Command prettier -ErrorAction SilentlyContinue) { $runner = 'prettier' }
elseif (Get-Command npx -ErrorAction SilentlyContinue) { $runner = 'npx'; $runnerArgs = @('--no-install', 'prettier') }
else {
    Confirm-IncompleteScan "no prettier runner found (node_modules/.bin/prettier, prettier on PATH, or npx)" `
        "Provision the prettier runner: install it in '$workingDir' (node_modules) or put it on PATH."
    exit 0
}

} else {
    $runner, $trustedConfig = Get-TrustedAppTool 'prettier'
    $runnerArgs = @()
}

Start-ScanTimer
Write-HookLog "Formatting... ($($files.Count) files in $workingDir)"

$prettierArgs = $runnerArgs + @('--write', '--ignore-unknown')
if ($env:SCAN_TRUST_REPO_CODE -ne '1') {
    if ($ExtraArgs) { throw 'Extra arguments require SCAN_TRUST_REPO_CODE=1' }
    $prettierArgs += @('--config', $trustedConfig)
}
foreach ($file in $files) { Assert-SafeWritePath (Join-Path $workingDirPath $file) }
if ($ExtraArgs) { $prettierArgs += $ExtraArgs }
$prettierArgs += '--'
$executionDir = $workingDirPath
if ($env:SCAN_TRUST_REPO_CODE -ne '1') {
    $executionDir = [IO.Path]::GetDirectoryName($trustedConfig)
    $prettierArgs += @($files | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $workingDirPath $_)) })
} else { $prettierArgs += $files }

# Guard Push-Location: selected files need the directory exactly as configured. With
# the opt-in, skip here, after the trusted-tool checks above, which still block.
if (-not (Test-Path -LiteralPath $workingDirPath -PathType Container)) {
    Confirm-IncompleteScan $missingDir $fixDir
    exit 0
}

Push-Location -LiteralPath $executionDir
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
