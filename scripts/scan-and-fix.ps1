<#
.SYNOPSIS
  scan-and-fix.ps1 — shared, versioned scanner used by the Claude Code Stop hook
  and on demand. Runs the configured scan(s) over the working tree and, with
  -AutoFix, writes a stable .claude/scan-findings.json for the agent to act on.

.DESCRIPTION
  This is the heavy, shared logic referenced by templates/claude/. The thin
  per-repo .claude hooks call into it. It fails open on missing tools (so a
  developer without trivy/semgrep is never hard-blocked) but fails CLOSED on
  real findings (non-zero exit) so the Stop hook can block "done".

.PARAMETER ScanType
  secrets | semgrep | terraform | csharp | typescript | all

.PARAMETER AutoFix
  Emit .claude/scan-findings.json (machine-readable) when findings are present.
#>
param(
    [ValidateSet('secrets', 'semgrep', 'terraform', 'csharp', 'typescript', 'all')]
    [string]$ScanType = 'secrets',
    [switch]$AutoFix
)

$ErrorActionPreference = 'Continue'
$results = @()

function Add-Result {
    param([string]$Tool, [int]$ExitCode, [string[]]$Issues, [string]$OutputTail)
    $script:results += [pscustomobject]@{
        tool       = $Tool
        exitCode   = $ExitCode
        passed     = ($ExitCode -eq 0)
        issues     = @($Issues)
        outputTail = $OutputTail
    }
}

function Test-Tool { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Get-IssueLines {
    param([string]$Text)
    if (-not $Text) { return @() }
    ($Text -split "`n" |
        Where-Object { $_ -match 'CRITICAL|HIGH|ERROR|Vulnerability|Secret|Misconfiguration|error ' } |
        Select-Object -First 25)
}

function Invoke-SecretScan {
    if (-not (Test-Tool 'trivy')) { Write-Host "[scan-and-fix] trivy not found; skipping secrets (fail-open)"; return }
    $out = & trivy fs . --scanners secret --severity CRITICAL,HIGH --exit-code 1 --quiet `
        --skip-dirs node_modules --skip-dirs dist --skip-dirs build --skip-dirs bin --skip-dirs obj --skip-dirs .terraform 2>&1
    $code = $LASTEXITCODE
    # SECURITY: never persist raw secret-scan output (it contains matched secrets) into
    # .claude/scan-findings.json, which the agent reads. Record only the pass/fail signal.
    $issues = if ($code -ne 0) { @('Secret findings detected — run `trivy fs . --scanners secret` locally to see them (redacted from findings file).') } else { @() }
    Add-Result -Tool 'Trivy Secrets' -ExitCode $code -Issues $issues -OutputTail ''
}

function Invoke-SemgrepScan {
    if (-not (Test-Tool 'semgrep')) { Write-Host "[scan-and-fix] semgrep not found; skipping (fail-open)"; return }
    $env:PYTHONUTF8 = '1'; $env:SEMGREP_SEND_METRICS = 'off'
    $out = & semgrep scan --config auto --error --metrics off --quiet 2>&1
    $code = $LASTEXITCODE
    $text = ($out -join "`n")
    Add-Result -Tool 'Semgrep SAST' -ExitCode $code -Issues (Get-IssueLines $text) -OutputTail ($text.Substring([Math]::Max(0, $text.Length - 3000)))
}

function Invoke-TerraformScan {
    if (-not (Test-Tool 'trivy')) { return }
    $out = & trivy config . --severity CRITICAL,HIGH --exit-code 1 --quiet --skip-dirs .terraform 2>&1
    $code = $LASTEXITCODE
    $text = ($out -join "`n")
    Add-Result -Tool 'Trivy IaC' -ExitCode $code -Issues (Get-IssueLines $text) -OutputTail ($text.Substring([Math]::Max(0, $text.Length - 3000)))
}

function Invoke-CSharpScan {
    if (-not (Test-Tool 'dotnet')) { return }
    # Reuse the shared dotnet-build hook so config (solution/working_dir) drives it.
    $hook = Join-Path $PSScriptRoot '..\hooks\dotnet-build.sh'
    $env:SCAN_HOOK_ID = 'dotnet-build'
    $disp = Join-Path $PSScriptRoot '..\hooks\dotnet-build.ps1'
    if (Test-Path $disp) {
        $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $disp 2>&1
        Add-Result -Tool 'dotnet build (Roslyn)' -ExitCode $LASTEXITCODE -Issues (Get-IssueLines ($out -join "`n")) -OutputTail (($out -join "`n"))
    }
}

function Invoke-TypeScriptScan {
    $disp = Join-Path $PSScriptRoot '..\hooks\semgrep-typescript.ps1'
    if (Test-Path $disp) {
        $env:SCAN_HOOK_ID = 'semgrep-typescript'
        $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $disp 2>&1
        Add-Result -Tool 'Semgrep (TypeScript)' -ExitCode $LASTEXITCODE -Issues (Get-IssueLines ($out -join "`n")) -OutputTail (($out -join "`n"))
    }
}

switch ($ScanType) {
    'secrets'    { Invoke-SecretScan }
    'semgrep'    { Invoke-SemgrepScan }
    'terraform'  { Invoke-TerraformScan }
    'csharp'     { Invoke-CSharpScan }
    'typescript' { Invoke-TypeScriptScan }
    'all'        { Invoke-SecretScan; Invoke-SemgrepScan; Invoke-TerraformScan; Invoke-CSharpScan; Invoke-TypeScriptScan }
}

$failed = @($results | Where-Object { -not $_.passed })
$hasErrors = $failed.Count -gt 0

if ($AutoFix -and $hasErrors) {
    if (-not (Test-Path '.claude')) { New-Item -ItemType Directory -Path '.claude' -Force | Out-Null }
    $doc = [pscustomobject]@{
        schemaVersion   = 1
        generatedAtUtc  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        scanType        = $ScanType
        autoFix         = $true
        summary         = @{ total = $results.Count; passed = ($results.Count - $failed.Count); failed = $failed.Count }
        hasErrors       = $hasErrors
        findings        = $results
    }
    $doc | ConvertTo-Json -Depth 6 | Set-Content -Path '.claude/scan-findings.json' -Encoding UTF8
}

foreach ($r in $results) {
    $status = if ($r.passed) { 'PASS' } else { 'FAIL' }
    Write-Host "[scan-and-fix] $status $($r.tool) (exit=$($r.exitCode))"
}

if ($hasErrors) { exit 1 } else { exit 0 }
