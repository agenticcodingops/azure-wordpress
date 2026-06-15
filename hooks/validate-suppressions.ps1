<#
    Note: No #Requires -Version 7.0 - must work on PowerShell 5.1 fallback from dispatcher
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

# Find a Python that ACTUALLY runs (Get-Command python3 may resolve the
# non-runnable Windows Store shim, which would fail-open and BYPASS validation).
$Python = Find-WorkingPython
if (-not $Python) {
    Write-HookWarn "No working Python interpreter found - skipping suppression validation (fail-open)"
    exit 0  # fail-open
}

# Look in $ConfigDir first, then fall back to the repo-root default so the Windows
# wrapper isn't blind to a root-level .scan-suppressions.yaml.
$SuppressionFile = Join-Path $ConfigDir ".scan-suppressions.yaml"
if (-not (Test-Path -LiteralPath $SuppressionFile)) {
    $rootSuppressionFile = ".scan-suppressions.yaml"
    if (Test-Path -LiteralPath $rootSuppressionFile) {
        $SuppressionFile = $rootSuppressionFile
    } else {
        Write-HookVerbose "No suppression file found at $SuppressionFile or $rootSuppressionFile - skipping"
        exit 0
    }
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
