# Validate the consumer index using the package-owned validator and schema.
param([Parameter(ValueFromRemainingArguments)]$ExtraArgs)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/common.ps1"
$py = Find-WorkingPython
if (-not $py) {
    if ($env:SCAN_ALLOW_TOOL_ERRORS -eq '1') { exit 0 }
    throw 'Python is required to validate staged scan-config.yaml'
}
& $py "$PSScriptRoot/../scripts/validate-scan-config.py" --staged
exit $LASTEXITCODE
