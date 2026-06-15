# common.ps1 — Shared PowerShell functions for hook scripts
# Dot-sourced by all .ps1 hook wrappers via:
#   . "$PSScriptRoot\lib\common.ps1"

# Guard against double-sourcing
if ($global:_CommonPS1Loaded) { return }
$global:_CommonPS1Loaded = $true

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-HookLog {
    param([string]$Message)
    Write-Host "[$env:SCAN_HOOK_ID] $Message"
}

function Write-HookWarn {
    param([string]$Message)
    Write-Warning "[$env:SCAN_HOOK_ID] WARNING: $Message"
}

function Write-HookError {
    param([string]$Message)
    Write-Error "[$env:SCAN_HOOK_ID] ERROR: $Message" -ErrorAction Continue
}

function Write-HookVerbose {
    param([string]$Message)
    if ($env:SCAN_VERBOSE -eq '1') {
        Write-Host "[$env:SCAN_HOOK_ID] DEBUG: $Message" -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# Exit code handling (fail-open)
# ---------------------------------------------------------------------------

# Classify a tool exit code:
#   exit 0 = no findings (pass)
#   exit 1 = security findings found (block)
#   exit 2+ = infrastructure error (fail-open, warn + allow)
function Get-HookExitCode {
    param(
        [Parameter(Mandatory)]
        [int]$ToolExitCode
    )

    switch ($ToolExitCode) {
        0 { return 0 }
        1 { return 1 }
        default {
            Write-HookWarn "Tool error (exit code $ToolExitCode) - allowing commit (fail-open)"
            return 0
        }
    }
}

# ---------------------------------------------------------------------------
# JSON output
# ---------------------------------------------------------------------------

function Ensure-ScanningDir {
    $scanDir = '.scanning'
    if (-not (Test-Path $scanDir)) {
        New-Item -ItemType Directory -Path $scanDir -Force | Out-Null
    }
}

function Write-ScanJson {
    param(
        [Parameter(Mandatory)]
        [string]$JsonContent
    )

    Ensure-ScanningDir
    $JsonContent | Set-Content -Path '.scanning/last-scan.json' -Encoding UTF8 -NoNewline
    Write-HookVerbose "Wrote scan results to .scanning/last-scan.json"
}

function New-ScanId {
    try {
        return [guid]::NewGuid().ToString()
    } catch {
        return "scan-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())-$(Get-Random)"
    }
}

function Build-PassJson {
    param(
        [Parameter(Mandatory)]
        [string]$Tool,
        [string]$ScanDirectory = '.',
        [int]$DurationMs = 0
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $scanId = New-ScanId

    # Escape backslashes and quotes for valid JSON strings (use .Replace for literal replacements)
    $safeScanDir = $ScanDirectory.Replace('\', '\\').Replace('"', '\"')

    return @"
{
  "schema_version": "1.0",
  "scan_id": "$scanId",
  "timestamp": "$timestamp",
  "duration_ms": $DurationMs,
  "scan_directory": "$safeScanDir",
  "tools_executed": ["$Tool"],
  "auto_fix_applied": false,
  "auto_fix_count": 0,
  "summary": {
    "total_findings": 0,
    "by_severity": {"CRITICAL": 0, "HIGH": 0, "MEDIUM": 0, "LOW": 0},
    "by_tool": {"$Tool": 0},
    "fixable": 0,
    "unfixable": 0
  },
  "findings": []
}
"@
}

function Build-FindingsJson {
    param(
        [Parameter(Mandatory)]
        [string]$Tool,
        [string]$ScanDirectory = '.',
        [int]$DurationMs = 0,
        [string]$FindingsArray = '[]',
        [int]$Critical = 0,
        [int]$High = 0,
        [int]$Medium = 0,
        [int]$Low = 0
    )

    $total = $Critical + $High + $Medium + $Low
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $scanId = New-ScanId

    # Escape backslashes and quotes for valid JSON strings (use .Replace for literal replacements)
    $safeScanDir = $ScanDirectory.Replace('\', '\\').Replace('"', '\"')

    return @"
{
  "schema_version": "1.0",
  "scan_id": "$scanId",
  "timestamp": "$timestamp",
  "duration_ms": $DurationMs,
  "scan_directory": "$safeScanDir",
  "tools_executed": ["$Tool"],
  "auto_fix_applied": false,
  "auto_fix_count": 0,
  "summary": {
    "total_findings": $total,
    "by_severity": {"CRITICAL": $Critical, "HIGH": $High, "MEDIUM": $Medium, "LOW": $Low},
    "by_tool": {"$Tool": $total},
    "fixable": 0,
    "unfixable": $total
  },
  "findings": $FindingsArray
}
"@
}

# ---------------------------------------------------------------------------
# Monorepo / directory detection
# ---------------------------------------------------------------------------

# Changed files for dir-detection: the staged index (pre-commit), or the push range
# when the index is empty (the usual case at pre-push), so pushed commits are still
# scanned. Best-effort — CI is the authoritative backstop.
function Get-ChangedFilesForDetect {
    $files = @(git diff --cached --name-only --diff-filter=ACMR 2>$null)
    if (-not $files -or $files.Count -eq 0) {
        $files = @(git diff --name-only --diff-filter=ACMR '@{push}' HEAD 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $files -or $files.Count -eq 0) {
            $files = @(git diff --name-only --diff-filter=ACMR '@{upstream}' HEAD 2>$null)
            if ($LASTEXITCODE -ne 0) { $files = @() }
        }
    }
    return @($files | Where-Object { $_ })
}

function Get-ChangedDirs {
    try {
        $gitAvailable = Get-Command git -ErrorAction SilentlyContinue
        if (-not $gitAvailable) {
            return @()
        }

        $isGitRepo = git rev-parse --is-inside-work-tree 2>$null
        if ($LASTEXITCODE -ne 0) {
            return @()
        }

        $changedFiles = Get-ChangedFilesForDetect | Where-Object { $_ -match '\.tf$' }

        if (-not $changedFiles -or $changedFiles.Count -eq 0) {
            # No changed .tf files — return empty so hooks skip scanning
            return @()
        }

        $dirs = $changedFiles | ForEach-Object {
            $parent = Split-Path $_ -Parent
            # Split-Path returns '' for root-level files — map to '.' (repo root)
            # so root files are scanned rather than dropped.
            if ($parent -eq '') { '.' } else { $parent }
        } | Sort-Object -Unique

        if (-not $dirs -or $dirs.Count -eq 0) {
            return @()
        }

        return $dirs
    } catch {
        return @()
    }
}

# Detect directories containing ANY staged files (not just .tf)
# Used by secret detection hooks which scan all file types
# Returns empty array when no files are staged
function Get-AllChangedDirs {
    try {
        $gitAvailable = Get-Command git -ErrorAction SilentlyContinue
        if (-not $gitAvailable) { return @() }

        $isGitRepo = git rev-parse --is-inside-work-tree 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }

        $changedFiles = Get-ChangedFilesForDetect

        if (-not $changedFiles -or $changedFiles.Count -eq 0) {
            return @()
        }

        $dirs = $changedFiles | ForEach-Object {
            $parent = Split-Path $_ -Parent
            # Split-Path returns '' for root-level files — map to '.' (repo root)
            # so root files are scanned rather than dropped.
            if ($parent -eq '') { '.' } else { $parent }
        } | Sort-Object -Unique

        if (-not $dirs -or $dirs.Count -eq 0) {
            return @()
        }

        return $dirs
    } catch {
        return @()
    }
}

function Get-TfFileCount {
    param(
        [string[]]$Directories
    )

    $count = 0
    foreach ($dir in $Directories) {
        if (Test-Path $dir -PathType Container) {
            $count += (Get-ChildItem -Path $dir -Filter '*.tf' -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '[\\/]\.terraform[\\/]' }).Count
        }
    }
    return $count
}

# ---------------------------------------------------------------------------
# App-code helpers (shared by csharp/typescript/sql hooks — STEP 2)
# ---------------------------------------------------------------------------

# Return staged files (ACMR) optionally filtered by extension (no dot, case-insensitive).
# Usage: $files = Get-StagedFiles -Extensions @('cs','csproj')
#        $files = Get-StagedFiles   # all staged files
function Get-StagedFiles {
    param([string[]]$Extensions = @())

    try {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return @() }
        $files = git diff --cached --name-only --diff-filter=ACMR 2>$null
        if (-not $files) { return @() }
        $files = @($files)
        if ($Extensions.Count -eq 0) { return $files }
        $patterns = $Extensions | ForEach-Object { [regex]::Escape(".$_") + '$' }
        $rx = [regex]::new(($patterns -join '|'), 'IgnoreCase')
        return @($files | Where-Object { $rx.IsMatch($_) })
    } catch {
        return @()
    }
}

# Export staged files (from the git index) into a fresh temp dir, preserving paths.
# Returns the temp dir path; caller must Remove-Item it.
function Export-StagedFilesToTempDir {
    param([string[]]$Files)

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "scan-staged-$(Get-Random)"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    foreach ($file in @($Files)) {
        if (-not $file) { continue }
        $fileDir = Split-Path $file -Parent
        if ($fileDir) {
            $targetDir = Join-Path $tmpDir $fileDir
            if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
        }
        $targetFile = Join-Path $tmpDir $file
        # Do NOT use -NoNewline: it strips trailing newlines and corrupts the
        # scanned input (line breaks must be preserved for accurate scanning).
        try { git show ":$file" 2>$null | Set-Content -LiteralPath $targetFile -Encoding UTF8 } catch { }
    }
    return $tmpDir
}

# Find a Python that ACTUALLY runs (skips the broken Windows Store python3 shim).
function Find-WorkingPython {
    foreach ($cand in @('python', 'python3', 'py')) {
        if (Get-Command $cand -ErrorAction SilentlyContinue) {
            try {
                & $cand -c "" 2>$null
                if ($LASTEXITCODE -eq 0) { return $cand }
            } catch { }
        }
    }
    return $null
}

# Read a dotted key from scan-config.yaml; returns $Default if missing/unparseable.
# Usage: $solution = Read-ScanConfigValue -Key 'languages.csharp.build.solution' -Default ''
function Read-ScanConfigValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [string]$Default = ''
    )

    $cfg = if ($env:SCAN_CONFIG_FILE) { $env:SCAN_CONFIG_FILE } else { 'scan-config.yaml' }
    if (-not (Test-Path $cfg)) { return $Default }

    $py = Find-WorkingPython
    if (-not $py) { return $Default }

    $script = @'
import sys
key, default, cfg = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    import yaml
    with open(cfg, encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
    cur = data
    for part in key.split("."):
        cur = cur[part]
    print(cur if cur is not None and cur != "" else default)
except Exception:
    print(default)
'@
    $tmp = New-TemporaryFile
    try {
        Set-Content -Path $tmp -Value $script -Encoding UTF8
        $out = & $py $tmp $Key $Default $cfg 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return $Default }
        return ($out | Select-Object -First 1).ToString().Trim()
    } catch {
        return $Default
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

# Count Semgrep findings by severity from a --json output file (native parse).
# ERROR->High, WARNING->Medium, INFO->Low. Returns a hashtable @{High;Medium;Low;Total}.
function Get-SemgrepCounts {
    param([Parameter(Mandatory)][string]$JsonPath)
    $res = @{ High = 0; Medium = 0; Low = 0; Total = 0 }
    try {
        $doc = Get-Content $JsonPath -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($r in @($doc.results)) {
            switch (("" + $r.extra.severity).ToUpper()) {
                'ERROR'   { $res.High++ }
                'WARNING' { $res.Medium++ }
                default   { $res.Low++ }
            }
        }
        $res.Total = $res.High + $res.Medium + $res.Low
    } catch { }
    return $res
}

# Print a concise list of Semgrep findings from a --json output file.
function Show-SemgrepFindings {
    param([Parameter(Mandatory)][string]$JsonPath)
    try {
        $doc = Get-Content $JsonPath -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($r in @($doc.results | Select-Object -First 25)) {
            $sev = ("" + $r.extra.severity).ToUpper()
            $msg = (("" + $r.extra.message) -split "`n")[0]
            Write-HookLog "  $sev  $($r.check_id)  $($r.path):$($r.start.line)"
            Write-HookLog "    $msg"
        }
    } catch { }
}

# Auto-detect nearest .slnx/.sln under a working dir when build.solution is empty.
function Find-DotnetSolution {
    param([string]$WorkingDir = '.')
    if (-not (Test-Path $WorkingDir)) { return '' }
    $sln = Get-ChildItem -Path $WorkingDir -Recurse -Depth 3 -Include '*.slnx', '*.sln' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($sln) { return $sln.FullName }
    return ''
}

# ---------------------------------------------------------------------------
# Config resolution
# ---------------------------------------------------------------------------

function Resolve-ScanConfig {
    param(
        [Parameter(Mandatory)]
        [string]$Filename,
        [string]$Fallback = ''
    )

    $configDir = if ($env:SCAN_CONFIG_DIR) { $env:SCAN_CONFIG_DIR } else { '.scanning/configs' }

    # Priority 1: Consuming repo's downloaded configs
    $configPath = Join-Path $configDir $Filename
    if (Test-Path $configPath) {
        return $configPath
    }

    # Priority 2: Fallback path
    if ($Fallback -and (Test-Path $Fallback)) {
        return $Fallback
    }

    return $null
}

# ---------------------------------------------------------------------------
# Trivy-specific helpers
# ---------------------------------------------------------------------------

function Invoke-TrivyWithRetry {
    param(
        [Parameter(Mandatory)]
        [string[]]$ArgumentList
    )

    # First attempt — invoke trivy directly with array splatting, no cmd /c
    $output = & trivy @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE

    # Check for DB lock
    $outputText = $output -join "`n"
    if ($outputText -match 'database.*locked') {
        Write-HookWarn "Trivy database locked, retrying in 2 seconds..."
        Start-Sleep -Seconds 2

        # Retry once
        $output = & trivy @ArgumentList 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = $output -join "`n"

        if ($outputText -match 'database.*locked') {
            Write-HookWarn "Trivy database still locked after retry"
            return @{ Output = $outputText; ExitCode = 2 }
        }
    }

    return @{ Output = $outputText; ExitCode = $exitCode }
}

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

function Test-ToolAvailable {
    param(
        [Parameter(Mandatory)]
        [string]$ToolName
    )

    if (-not (Get-Command $ToolName -ErrorAction SilentlyContinue)) {
        Write-HookWarn "$ToolName not found on PATH - allowing commit (fail-open)"
        return $false
    }
    return $true
}

function Start-ScanTimer {
    $script:ScanStartTime = Get-Date
}

function Stop-ScanTimer {
    if ($script:ScanStartTime) {
        $elapsed = (Get-Date) - $script:ScanStartTime
        return [int]$elapsed.TotalMilliseconds
    }
    return 0
}

function Format-FindingSummary {
    param(
        [int]$Critical = 0,
        [int]$High = 0,
        [int]$Medium = 0,
        [int]$Low = 0
    )

    $total = $Critical + $High + $Medium + $Low
    return "$total findings ($Critical critical, $High high, $Medium medium, $Low low)"
}

# Print actionable details for Trivy IaC findings
function Show-TrivyIacFindings {
    param([string]$JsonOutput)

    if (-not $JsonOutput) { return }

    try {
        $parsed = $JsonOutput | ConvertFrom-Json
        $findings = @()
        foreach ($result in $parsed.Results) {
            $target = $result.Target
            foreach ($misconfig in $result.Misconfigurations) {
                $findings += [PSCustomObject]@{
                    Severity   = $misconfig.Severity
                    ID         = $misconfig.ID
                    Title      = $misconfig.Title
                    Resolution = $misconfig.Resolution
                    Target     = $target
                    StartLine  = $misconfig.CauseMetadata.StartLine
                    EndLine    = $misconfig.CauseMetadata.EndLine
                    Resource   = $misconfig.CauseMetadata.Resource
                }
            }
        }

        if ($findings.Count -gt 0) {
            Write-HookLog ""
            foreach ($f in $findings | Sort-Object @{Expression={
                switch ($f.Severity) { 'CRITICAL' {0} 'HIGH' {1} 'MEDIUM' {2} default {3} }
            }}) {
                Write-HookLog "  $($f.Severity)  $($f.ID)  $($f.Target):$($f.StartLine)-$($f.EndLine)"
                Write-HookLog "    $($f.Title)"
                Write-HookLog "    Resource: $($f.Resource)"
                Write-HookLog "    Fix: $($f.Resolution)"
            }
            Write-HookLog ""
        }
    } catch {
        # Silently skip if JSON parsing fails
    }
}

# Print actionable details for Trivy secret findings
function Show-TrivySecretFindings {
    param([string]$JsonOutput)

    if (-not $JsonOutput) { return }

    try {
        $parsed = $JsonOutput | ConvertFrom-Json
        $findings = @()
        foreach ($result in $parsed.Results) {
            $target = $result.Target
            foreach ($secret in $result.Secrets) {
                $findings += [PSCustomObject]@{
                    Severity  = $secret.Severity
                    RuleID    = $secret.RuleID
                    Title     = $secret.Title
                    Target    = $target
                    StartLine = $secret.StartLine
                    EndLine   = $secret.EndLine
                    Match     = $secret.Match
                }
            }
        }

        if ($findings.Count -gt 0) {
            Write-HookLog ""
            foreach ($f in $findings) {
                Write-HookLog "  $($f.Severity)  $($f.RuleID)  $($f.Target):$($f.StartLine)-$($f.EndLine)"
                Write-HookLog "    $($f.Title)"
                # Do NOT print $f.Match — it is the raw secret value. file:line + rule
                # is enough to locate and fix it without leaking it to logs.
            }
            Write-HookLog ""
        }
    } catch {
        # Silently skip if JSON parsing fails
    }
}

# Print actionable details for Checkov findings
function Show-CheckovFindings {
    param([string]$JsonOutput)

    if (-not $JsonOutput) { return }

    try {
        $parsed = $JsonOutput | ConvertFrom-Json
        $failedChecks = $parsed.results.failed_checks
        if (-not $failedChecks) { return }

        $findings = @()
        foreach ($check in $failedChecks) {
            $sev = if ($check.severity) { $check.severity } else { 'UNKNOWN' }
            $findings += [PSCustomObject]@{
                Severity  = $sev
                ID        = $check.check_id
                Name      = $check.check_name
                Resource  = $check.resource_address
                File      = $check.file_path
                StartLine = $check.file_line_range[0]
                EndLine   = $check.file_line_range[1]
                Guideline = $check.guideline
            }
        }

        if ($findings.Count -gt 0) {
            Write-HookLog ""
            foreach ($f in $findings | Sort-Object @{Expression={
                switch ($f.Severity) { 'CRITICAL' {0} 'HIGH' {1} 'MEDIUM' {2} default {3} }
            }}) {
                Write-HookLog "  $($f.Severity)  $($f.ID)  $($f.File):$($f.StartLine)-$($f.EndLine)"
                Write-HookLog "    $($f.Name)"
                Write-HookLog "    Resource: $($f.Resource)"
                if ($f.Guideline) {
                    Write-HookLog "    Guide: $($f.Guideline)"
                }
            }
            Write-HookLog ""
        }
    } catch {
        # Silently skip if JSON parsing fails
    }
}

# Print actionable details for TFLint findings
function Show-TflintFindings {
    param([string]$JsonOutput)

    if (-not $JsonOutput) { return }

    try {
        $parsed = $JsonOutput | ConvertFrom-Json
        if (-not $parsed.issues) { return }

        $findings = @()
        foreach ($issue in $parsed.issues) {
            $findings += [PSCustomObject]@{
                Severity = $issue.rule.severity
                Name     = $issue.rule.name
                Message  = $issue.message
                File     = $issue.range.filename
                Start    = $issue.range.start.line
                End      = $issue.range.end.line
            }
        }

        if ($findings.Count -gt 0) {
            Write-HookLog ""
            foreach ($f in $findings | Sort-Object @{Expression={
                switch ($f.Severity) { 'error' {0} 'warning' {1} default {2} }
            }}) {
                Write-HookLog "  $($f.Severity.ToUpper())  $($f.Name)  $($f.File):$($f.Start)-$($f.End)"
                Write-HookLog "    $($f.Message)"
            }
            Write-HookLog ""
        }
    } catch {
        # Silently skip if JSON parsing fails
    }
}
