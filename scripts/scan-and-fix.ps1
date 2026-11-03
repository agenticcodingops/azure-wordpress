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
  C# scans run when languages.csharp.enabled is true or the working tree contains
  .sln, .slnx or .csproj files (excluding .git, bin, obj and node_modules).
  Explicit enabled: false always skips C#, including with -ScanType all.
  When C# is in use, missing solutions/tools and builds that cannot start or fail
  produce failed results.

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
. "$PSScriptRoot/../hooks/lib/common.ps1"

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

function Find-CSharpInput {
    param([string]$WorkingDir = '.', [switch]$SolutionsOnly)
    # Walk directories explicitly so excluded trees are never traversed. Do not
    # follow directory links outside the working tree or into recursive cycles.
    # Breadth-first discovery prefers the nearest solution without a depth cap.
    $extensions = if ($SolutionsOnly) { @('.sln', '.slnx') } else { @('.sln', '.slnx', '.csproj') }
    $pending = [System.Collections.Generic.Queue[string]]::new()
    $pending.Enqueue((Get-Item -LiteralPath $WorkingDir -ErrorAction Stop).FullName)
    while ($pending.Count -gt 0) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Dequeue() -Force -ErrorAction Stop) {
            if ($item.PSIsContainer) {
                if ($item.Name -notin @('.git', 'bin', 'obj', 'node_modules') -and
                    -not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    $pending.Enqueue($item.FullName)
                }
            } elseif ($item.Extension -in $extensions) {
                return $item.FullName
            }
        }
    }
    return ''
}

function Invoke-CSharpScan {
    $code = 1
    $csText = ''
    try {
        $enabled = Read-ScanConfigValue -Key 'languages.csharp.enabled' -Default ''
        if ($enabled -eq 'false') {
            Write-Host '[scan-and-fix] C# disabled in scan-config.yaml; skipping C#'
            return
        }
        if ($enabled -ne 'true' -and -not (Find-CSharpInput)) {
            Write-Host '[scan-and-fix] No C# solution or project files found; skipping C#'
            return
        }
        $workingDir = Read-ScanConfigValue -Key 'languages.csharp.build.working_dir' -Default '.'
        $solution = Read-ScanConfigValue -Key 'languages.csharp.build.solution' -Default ''
        # The push build hook rejects the same configured paths; keep both runners consistent.
        foreach ($configured in @($workingDir, $solution)) {
            $normalised = $configured.Replace('\', '/')
            if ($normalised.StartsWith('/') -or $configured.Contains(':') -or ($normalised -split '/') -contains '..') {
                throw "Build paths must remain inside the working tree: $configured"
            }
        }
        if (-not (Test-Path -LiteralPath $workingDir -PathType Container)) {
            throw "Build working directory not found: $workingDir"
        }
        # Discovery returns an absolute path; configured paths are relative to
        # working_dir, just as they are in the push build hook.
        if (-not $solution) { $solution = Find-CSharpInput -WorkingDir $workingDir -SolutionsOnly }
        Push-Location -LiteralPath $workingDir -ErrorAction Stop
        try {
            if (-not $solution -or -not (Test-Path -LiteralPath $solution -PathType Leaf)) {
                throw 'No solution found; configure languages.csharp.build.solution'
            }
            if (-not (Test-Tool 'dotnet')) { throw 'dotnet not found; build cannot start' }
            # This path scans the live working tree. Push hooks still require
            # a complete Git transaction and their materialised snapshot.
            $global:LASTEXITCODE = $null
            $out = & dotnet build $solution /p:AnalysisMode=AllEnabledByDefault --nologo 2>&1
            if ($null -eq $LASTEXITCODE) { throw 'Build did not return an exit code' }
            $code = $LASTEXITCODE
            $csText = ($out -join "`n")
        } finally {
            Pop-Location
        }
    } catch {
        $csText = $_.Exception.Message
    }
    Add-Result -Tool 'dotnet build (Roslyn)' -ExitCode $code -Issues (Get-IssueLines $csText) -OutputTail ($csText.Substring([Math]::Max(0, $csText.Length - 3000)))
}

function Invoke-TypeScriptScan {
    $disp = Join-Path $PSScriptRoot '..\hooks\semgrep-typescript.ps1'
    if (Test-Path $disp) {
        $env:SCAN_HOOK_ID = 'semgrep-typescript'
        $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $disp 2>&1
        $tsText = ($out -join "`n")
        Add-Result -Tool 'Semgrep (TypeScript)' -ExitCode $LASTEXITCODE -Issues (Get-IssueLines $tsText) -OutputTail ($tsText.Substring([Math]::Max(0, $tsText.Length - 3000)))
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
    Assert-SafeWritePath '.claude/scan-findings.json'
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
