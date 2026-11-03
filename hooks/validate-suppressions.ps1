$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/common.ps1"
$python = Find-WorkingPython
if (-not $python) { throw 'Suppression validation requires Python' }
# Resolve suppressions.file using the same strict resolver as CI.
$file = & $python "$PSScriptRoot/../scripts/scan_policy.py"
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve the active suppression registry' }
if (-not (Test-Path -LiteralPath $file)) { exit 0 }
$arguments = @("$PSScriptRoot/validate-suppressions.py")
if ($env:SCAN_ALLOW_LEGACY_EXCEPTIONS -eq '1') { $arguments += '--allow-legacy-exceptions' }
$arguments += @('--', $file)
& $python @arguments
exit $LASTEXITCODE
