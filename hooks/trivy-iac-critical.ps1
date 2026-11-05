# trivy-iac-critical.ps1 — Trivy IaC scan for CRITICAL misconfigurations only
# Stage: pre-commit | Severity: CRITICAL only | --skip-check-update
param([Parameter(ValueFromRemainingArguments)]$ExtraArgs)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"

Invoke-StagedSnapshot -HookPath $PSCommandPath -HookArguments $ExtraArgs

# Verify tool availability
$scanner = Test-ToolAvailable 'trivy'
if (-not $scanner) { exit 0 }

Start-ScanTimer

# Detect scan directories
$scanDirs = Get-ChangedDirs
if (-not $scanDirs -or $scanDirs.Count -eq 0) {
    Write-HookLog "PASS: No Terraform files staged"
    exit 0
}
$fileCount = Get-TfFileCount -Directories $scanDirs
Write-HookLog "Scanning... ($fileCount files in $($scanDirs.Count) directories)"

$overallExit = 0
$totalCritical = 0

foreach ($dir in $scanDirs) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }

    # Build Trivy arguments as array — safe for paths with spaces/special chars
    $trivyArgs = @('config', '--severity', 'CRITICAL', '--exit-code', '1', '--format', 'json', '--skip-check-update', '--quiet')
    if ($env:SCAN_INDEX_SNAPSHOT -eq '1') {
        $automaticVariables = [string[]]@([IO.Directory]::GetFiles($dir, '*.auto.tfvars'))
        [Array]::Sort($automaticVariables, [StringComparer]::Ordinal)
        foreach ($variableFile in (@((Join-Path $dir 'terraform.tfvars')) + $automaticVariables)) {
            if (Test-Path -LiteralPath $variableFile -PathType Leaf) {
                $trivyArgs += @('--tf-vars', $variableFile)
            }
        }
    }

    # Check for config file
    $configFile = Resolve-ScanConfig -Filename '.trivyignore'
    if ($configFile) {
        $trivyArgs += @('--ignorefile', $configFile)
    }

    # Add extra args
    if ($ExtraArgs) {
        $trivyArgs += $ExtraArgs
    }

$trivyArgs += @('--', $dir)

    # Run Trivy with retry
    $result = Invoke-TrivyWithRetry -ToolPath $scanner -ArgumentList $trivyArgs

    if ($env:SCAN_INDEX_SNAPSHOT -eq '1' -and $result.ExitCode -eq 1) {
        $py = Find-WorkingPython
        if (-not $py) { throw 'Python is required to select commit findings' }
        $savedOutputEncoding = $OutputEncoding
        try {
            $OutputEncoding = [Text.UTF8Encoding]::new($false)
            $filtered = $result.Output | & $py -I "$PSScriptRoot/lib/trivy_selected.py" $dir $env:SCAN_PUSH_FILES
            $filterExit = $LASTEXITCODE
        } finally {
            $OutputEncoding = $savedOutputEncoding
        }
        if ($filterExit -notin @(0, 1)) { throw 'Invalid commit findings report; scan incomplete' }
        $result = @{ Output = $filtered -join "`n"; ExitCode = $filterExit }
    }

    if ($result.ExitCode -eq 1) {
        # Parse findings
        try {
            $json = $result.Output | ConvertFrom-Json
            $critical = @($json.Results | ForEach-Object { $_.Misconfigurations } |
                Where-Object { $_.Severity -eq 'CRITICAL' }).Count
            $totalCritical += [int]$critical
        } catch {
            $totalCritical += 1
        }
        # Show actionable details so developers know what to fix
        Show-TrivyIacFindings -JsonOutput $result.Output
        $overallExit = 1
    } elseif ($result.ExitCode -ge 2) {
        # Infrastructure error — fail-open
        $null = Get-HookExitCode -ToolExitCode $result.ExitCode
    }
}

$durationMs = Stop-ScanTimer

if ($overallExit -eq 0) {
    Write-HookLog "PASS: No findings above threshold"
    Write-ScanJson (Build-PassJson -Tool 'trivy' -DurationMs $durationMs)
} else {
    Write-HookLog "FAIL: $(Format-FindingSummary -Critical $totalCritical)"
    Write-ScanJson (Build-FindingsJson -Tool 'trivy' -DurationMs $durationMs -Critical $totalCritical)
}

exit $overallExit
