<#
    Note: No #Requires -Version 7.0 — must work on PowerShell 5.1 fallback from dispatcher
#>
<#
.SYNOPSIS
    Shell wrapper for Python suppression validator.
.DESCRIPTION
    Called by dispatcher.sh on Windows systems.
    Delegates to hooks/validate-suppressions.py.
#>

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir\lib\common.ps1"

$ConfigDir = if ($env:SCAN_CONFIG_DIR) { $env:SCAN_CONFIG_DIR } else { ".scanning/configs" }

# Find Python
$Python = $null
if (Get-Command python3 -ErrorAction SilentlyContinue) {
    $Python = "python3"
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $Python = "python"
} else {
    Write-HookVerbose "Python not found - cannot run suppression validation"
    exit 0  # fail-open
}

$SuppressionFile = Join-Path $ConfigDir ".scan-suppressions.yaml"
if (-not (Test-Path $SuppressionFile)) {
    Write-HookVerbose "No suppression file found at $SuppressionFile - skipping"
    exit 0
}

Write-HookVerbose "Running suppression validation with $Python"

$exitCode = 0
try {
    & $Python "$ScriptDir\validate-suppressions.py" $SuppressionFile
    $exitCode = $LASTEXITCODE
} catch {
    $exitCode = 2
}

$hookExit = Get-HookExitCode -ToolExitCode $exitCode
exit $hookExit
