# common.ps1 — Shared PowerShell functions for hook scripts
# Dot-sourced by all .ps1 hook wrappers via:
#   . "$PSScriptRoot\lib\common.ps1"

# Guard against double-sourcing
if ($global:_CommonPS1Loaded) { return }
$global:_CommonPS1Loaded = $true

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/tool-paths.ps1"

function Invoke-PushSnapshot {
    param([string]$HookPath, [object[]]$HookArguments)
    if ($env:SCAN_PUSH_SNAPSHOT -eq '1' -or $env:SCAN_LEGACY_PUSH_STATE -eq '1') { return }
    $py = Find-WorkingPython
    if (-not $py) { throw 'Python is required for push snapshots' }
    $runner = Join-Path (Split-Path -Parent $HookPath) 'pre-push.py'
    # Ignore Python environment paths and the checkout, retaining trusted user packages.
    & $py -E -P $runner --shell ps1 --hooks ([IO.Path]::GetFileNameWithoutExtension($HookPath)) @HookArguments
    exit $LASTEXITCODE
}

function Invoke-StagedSnapshot {
    param([string]$HookPath, [object[]]$HookArguments)
    if ($env:SCAN_INDEX_SNAPSHOT -eq '1') { return }
    $py = Find-WorkingPython
    if (-not $py) { throw 'Python is required for index snapshots' }
    $runner = Join-Path (Split-Path -Parent $HookPath) 'pre-commit.py'
    & $py -E -P $runner --shell ps1 ([IO.Path]::GetFileNameWithoutExtension($HookPath)) @HookArguments
    exit $LASTEXITCODE
}

function New-PassiveCheckovPolicy {
    param([object[]]$ExtraArgs)
    # Consume only Git's conventional remote pair in the explicit legacy mode.
    if ($env:SCAN_LEGACY_PUSH_STATE -eq '1' -and $env:SCAN_PUSH_SNAPSHOT -ne '1' -and
        @($ExtraArgs).Count -eq 2 -and $ExtraArgs[0] -and $ExtraArgs[1] -and
        -not ([string]$ExtraArgs[0]).StartsWith('-') -and -not ([string]$ExtraArgs[1]).StartsWith('-')) {
        $ExtraArgs = @()
    }
    if ($ExtraArgs) { throw 'Checkov extra arguments are disabled' }
    $py = Find-WorkingPython
    if (-not $py) { throw 'Python is required for passive Checkov policy' }
    $source = Resolve-ScanConfig -Filename '.checkov.yaml'
    $helper = Join-Path $PSScriptRoot 'checkov_policy.py'
    $policy = & $py -E -P $helper $source
    if ($LASTEXITCODE -ne 0) { throw 'Checkov policy rejected; scan incomplete' }
    $temporary = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($temporary, ($policy -join "`n"))
        return $temporary
    } catch {
        Remove-Item -LiteralPath $temporary -Force
        throw
    }
}

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
# Exit code handling (block incomplete scans unless explicitly opted out)
# ---------------------------------------------------------------------------

# Classify a tool exit code:
#   exit 0 = no findings (pass)
#   exit 1 = security findings found (block)
#   exit 2+ = infrastructure error (block; explicit local opt-in warns + allows)
function Get-HookExitCode {
    param(
        [Parameter(Mandatory)]
        [int]$ToolExitCode
    )

    switch ($ToolExitCode) {
        0 { return 0 }
        1 { return 1 }
        default {
            if ($env:SCAN_ALLOW_TOOL_ERRORS -eq '1') {
                Write-HookWarn "Tool error (exit code $ToolExitCode); explicit local fail-open opt-in"
                return 0
            }
            throw "Tool error (exit code $ToolExitCode); scan incomplete"
        }
    }
}

# ---------------------------------------------------------------------------
# JSON output
# ---------------------------------------------------------------------------

function Resolve-HookPath {
    param([string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Assert-SafeWritePath {
    param([string]$Path)
    $current = Resolve-HookPath $Path
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Refusing a symlink or reparse point in output path'
        }
        $parent = [IO.Directory]::GetParent($current)
        $current = if ($parent) { $parent.FullName } else { $null }
    }
}

function Assert-SafeTree {
    param([string]$Path)
    Assert-SafeWritePath $Path
    if (Test-Path -LiteralPath $Path -PathType Container) {
        foreach ($item in Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Refusing a symlink or reparse point in output tree'
            }
        }
    }
}

function Ensure-ScanningDir {
    Assert-SafeWritePath '.scanning/last-scan.json'
    if (-not (Test-Path -LiteralPath '.scanning')) {
        New-Item -ItemType Directory -Path '.scanning' | Out-Null
    }
}

function Write-ScanJson {
    param([Parameter(Mandatory)][string]$JsonContent)
    $temporary = Resolve-HookPath (Join-Path '.scanning' ('.scan-write-' + [guid]::NewGuid()))
    $destination = Resolve-HookPath '.scanning/last-scan.json'
    $prepared = $false
    $assertReportPath = {
        Assert-SafeWritePath '.scanning'
        # FileInfo.Attributes can return -1 after another writer removes the
        # report, falsely setting every flag. Read the leaf attributes directly;
        # a vanished report is expected, but an observed reparse point is fatal.
        try { $attributes = [IO.File]::GetAttributes($destination) }
        catch [IO.FileNotFoundException] { return }
        catch [IO.DirectoryNotFoundException] { return }
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Refusing a symlink or reparse point in output path'
        }
    }
    try {
        # Parallel hooks can create the directory/report or replace the destination
        # between any two filesystem calls. Only filesystem mutations retry;
        # safety-check failures must terminate the write immediately.
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            $checkingPath = $true
            try {
                & $assertReportPath
                $checkingPath = $false
                [IO.Directory]::CreateDirectory((Resolve-HookPath '.scanning')) | Out-Null
                if (-not $prepared -or -not [IO.File]::Exists($temporary)) {
                    [IO.File]::WriteAllText($temporary, $JsonContent)
                    $prepared = $true
                }
                $checkingPath = $true
                & $assertReportPath
                $checkingPath = $false
                if ([IO.File]::Exists($destination)) {
                    [IO.File]::Replace($temporary, $destination, [NullString]::Value)
                } else {
                    [IO.File]::Move($temporary, $destination)
                }
                return
            } catch [IO.IOException], [UnauthorizedAccessException] {
                if ($checkingPath -or $attempt -eq 19) { throw }
                Start-Sleep -Milliseconds 50
            }
        }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Resolve-ExternalRealPath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    for ($hop = 0; $hop -lt 40; $hop++) {
        $current = $full
        $resolved = $false
        while ($current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
            if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                if ($item.PSObject.Methods['ResolveLinkTarget']) {
                    $target = $item.ResolveLinkTarget($true)
                    $target = if ($target) { $target.FullName } else { $null }
                } else {
                    # Windows PowerShell 5.1 exposes link targets as an adapted
                    # property; .NET Framework has no ResolveLinkTarget method.
                    $targets = @($item.Target)
                    if ($targets.Count -ne 1) {
                        Write-Error 'Cannot resolve trusted path link' -ErrorId UnresolvableTrustedPathLink -ErrorAction Stop
                    }
                    $target = $targets[0]
                    if ($target -and -not [IO.Path]::IsPathRooted($target)) {
                        $target = Join-Path ([IO.Path]::GetDirectoryName($current)) $target
                    }
                }
                if (-not $target) {
                    Write-Error 'Cannot resolve trusted path link' -ErrorId UnresolvableTrustedPathLink -ErrorAction Stop
                }
                $suffix = $full.Substring($current.Length).TrimStart('/', '\')
                $full = [IO.Path]::GetFullPath($(if ($suffix) { Join-Path $target $suffix } else { $target }))
                $resolved = $true
                break
            }
            $parent = [IO.Directory]::GetParent($current)
            $current = if ($parent) { $parent.FullName } else { $null }
        }
        if (-not $resolved) { return $full }
    }
    throw 'Too many links in trusted path'
}

function Assert-ExternalPath {
    param([string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'Trusted path must be absolute' }
    $snapshot = $env:SCAN_PUSH_SNAPSHOT -eq '1' -or $env:SCAN_INDEX_SNAPSHOT -eq '1'
    $root = if ($snapshot) { (Get-Location).Path } else {
        Assert-GitAvailable
        & git rev-parse --show-toplevel 2>$null
    }
    if (-not $root) { $root = (Get-Location).Path }
    $roots = @($root)
    if ($snapshot -and $env:SCAN_CONSUMER_ROOT) {
        $roots += $env:SCAN_CONSUMER_ROOT
    }
    $full = Resolve-ExternalRealPath $Path
    foreach ($boundary in $roots) {
        $boundary = (Resolve-ExternalRealPath $boundary).TrimEnd('/', '\')
        if ($full -eq $boundary -or $full.StartsWith($boundary + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Trusted path must be outside the scanned and consumer checkouts'
        }
    }
}

function Assert-TrustedTflintConfig {
    param([string]$Path)
    Assert-ExternalPath $Path
    if (-not $Path.EndsWith('.hcl', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Trusted linter configuration must be an HCL file ending in .hcl'
    }
    if ((Get-Content -LiteralPath $Path -Raw) -cmatch 'plugin_dir') {
        throw 'Remove plugin_dir from the trusted config; use SCAN_TFLINT_PLUGIN_DIR'
    }
}

function Get-TrustedAppTool {
    param([string]$Tool)
    $bin = [Environment]::GetEnvironmentVariable("SCAN_$($Tool.ToUpper())_BIN")
    $config = [Environment]::GetEnvironmentVariable("SCAN_$($Tool.ToUpper())_CONFIG")
    foreach ($path in @($bin, $config)) {
        if (-not $path -or -not [IO.Path]::IsPathRooted($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Set SCAN_$($Tool.ToUpper())_BIN and SCAN_$($Tool.ToUpper())_CONFIG to external trusted files"
        }
        Assert-ExternalPath $path
    }
    return @($bin, $config)
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
  "scan_timestamp": "$timestamp",
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
  "scan_timestamp": "$timestamp",
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
# Read the native stdout stream intact before splitting on NUL. PowerShell's
# native command pipeline otherwise splits newline-containing pathnames.
function Assert-GitAvailable {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git is required to read scan inputs; scan incomplete'
    }
}

function Invoke-GitPaths {
    param([string[]]$Arguments)
    Assert-GitAvailable
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = 'git'
    $info.Arguments = $Arguments -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        $null = $process.Start()
        $stderr = $process.StandardError.ReadToEndAsync()
        $output = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw 'Could not enumerate scan inputs' }
        return @($output.Split([char]0) | Where-Object { $_ -ne '' })
    } finally { $process.Dispose() }
}

function Get-ChangedFilesForDetect {
    if ($env:SCAN_PUSH_FILES) {
        return @([IO.File]::ReadAllText($env:SCAN_PUSH_FILES).Split([char]0) | Where-Object { $_ -ne '' })
    }
    $files = @(Invoke-GitPaths -Arguments @('diff', '--cached', '--name-only', '-z', '--diff-filter=ACMR', '--'))
    if ($files.Count -eq 0) {
        git rev-parse --verify -q '@{push}' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $files = @(Invoke-GitPaths -Arguments @('diff', '--name-only', '-z', '--diff-filter=ACMR', '@{push}', 'HEAD', '--'))
        }
        if ($files.Count -eq 0) {
            git rev-parse --verify -q '@{upstream}' 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $files = @(Invoke-GitPaths -Arguments @('diff', '--name-only', '-z', '--diff-filter=ACMR', '@{upstream}', 'HEAD', '--'))
            }
        }
    }
    return $files
}

function Get-OrdinalUniquePaths {
    param([string[]]$Paths)
    $unique = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($path in $Paths) { $null = $unique.Add($path) }
    [string[]]$ordered = @($unique)
    [Array]::Sort($ordered, [System.StringComparer]::Ordinal)
    return $ordered
}

function Get-ChangedDirs {
    try {
        if (-not $env:SCAN_PUSH_FILES) {
            Assert-GitAvailable
            $isGitRepo = git rev-parse --is-inside-work-tree 2>$null
            if ($LASTEXITCODE -ne 0) {
                if ($env:SCAN_PUSH_SNAPSHOT -eq '1') { throw 'Could not enumerate push scan inputs; scan incomplete' }
                return @()
            }
        }

        $changedFiles = Get-ChangedFilesForDetect | Where-Object { $_ -match '\.tf(?:\.json)?$' }

        if (-not $changedFiles -or $changedFiles.Count -eq 0) {
            # No changed .tf files — return empty so hooks skip scanning
            return @()
        }

        $dirs = $changedFiles | ForEach-Object {
            $parent = Split-Path -LiteralPath $_
            # Split-Path returns '' for root-level files — map to '.' (repo root)
            # so root files are scanned rather than dropped.
            if ($parent -eq '') { '.' } else { $parent }
        }
        $dirs = @(Get-OrdinalUniquePaths -Paths @($dirs))

        if (-not $dirs -or $dirs.Count -eq 0) {
            return @()
        }

        return $dirs
    } catch { throw }
}

# Detect directories containing ANY staged files (not just .tf)
# Used by secret detection hooks which scan all file types
# Returns empty array when no files are staged
function Get-AllChangedDirs {
    try {
        if (-not $env:SCAN_PUSH_FILES) {
            Assert-GitAvailable
            $isGitRepo = git rev-parse --is-inside-work-tree 2>$null
            if ($LASTEXITCODE -ne 0) {
                if ($env:SCAN_PUSH_SNAPSHOT -eq '1') { throw 'Could not enumerate push scan inputs; scan incomplete' }
                return @()
            }
        }

        $changedFiles = Get-ChangedFilesForDetect

        if (-not $changedFiles -or $changedFiles.Count -eq 0) {
            return @()
        }

        $dirs = $changedFiles | ForEach-Object {
            $parent = Split-Path -LiteralPath $_
            # Split-Path returns '' for root-level files — map to '.' (repo root)
            # so root files are scanned rather than dropped.
            if ($parent -eq '') { '.' } else { $parent }
        }
        $dirs = @(Get-OrdinalUniquePaths -Paths @($dirs))

        if (-not $dirs -or $dirs.Count -eq 0) {
            return @()
        }

        return $dirs
    } catch { throw }
}

function Get-TfFileCount {
    param(
        [string[]]$Directories
    )

    $count = 0
    foreach ($dir in $Directories) {
        if (Test-Path -LiteralPath $dir -PathType Container) {
            $count += (Get-ChildItem -LiteralPath $dir -File -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '\.tf(?:\.json)?$' -and $_.FullName -notmatch '[\\/]\.terraform[\\/]' }).Count
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
        $files = if ($env:SCAN_PUSH_FILES) { @(Get-ChangedFilesForDetect) } else {
            Assert-GitAvailable
            @(Invoke-GitPaths -Arguments @('diff', '--cached', '--name-only', '-z', '--diff-filter=ACMR', '--'))
        }
        if (-not $files) { return @() }
        $files = @($files)
        if ($Extensions.Count -eq 0) { return $files }
        $patterns = $Extensions | ForEach-Object { [regex]::Escape(".$_") + '$' }
        $rx = [regex]::new(($patterns -join '|'), 'IgnoreCase')
        return @($files | Where-Object { $rx.IsMatch($_) })
    } catch { throw }
}

# Export staged files (from the git index) into a fresh temp dir, preserving paths.
# Returns the temp dir path; caller must Remove-Item it.
function Export-StagedFilesToTempDir {
    param([string[]]$Files)

    Assert-GitAvailable
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "scan-staged-$(Get-Random)"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    foreach ($file in @($Files)) {
        if (-not $file) { continue }
        $fileDir = Split-Path -LiteralPath $file
        if ($fileDir) {
            $targetDir = Join-Path $tmpDir $fileDir
            if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
        }
        $targetFile = Join-Path $tmpDir $file
        # Do NOT use -NoNewline: it strips trailing newlines and corrupts the
        # scanned input (line breaks must be preserved for accurate scanning).
        try {
            $content = git show ":$file" 2>$null
            if ($LASTEXITCODE -ne 0) { throw "git show exit $LASTEXITCODE" }
            $content | Set-Content -LiteralPath $targetFile -Encoding UTF8
        } catch {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force
            throw "Could not export staged '$file'; scan incomplete"
        }
    }
    return $tmpDir
}

# Require Python 3.11+ using the config reader's safe-path flags; skip broken
# launcher shims and older interpreters without disabling trusted user packages.
function Find-WorkingPython {
    foreach ($cand in @('python', 'python3', 'py')) {
        if (Get-Command $cand -CommandType Application -ErrorAction SilentlyContinue) {
            try { $candidate = Resolve-VerifiedPython -Name $cand }
            catch {
                # The resolver checks lexical and invoked identities before
                # returning this error. Only opaque external aliases may skip.
                if ($_.FullyQualifiedErrorId -like 'UnresolvableTrustedPathLink*') { continue }
                throw
            }
            try {
                & $candidate -E -P -c "pass" 2>$null
                if ($LASTEXITCODE -eq 0) { return $candidate }
            } catch { }
        }
    }
    return $null
}

# Read a dotted string key; defaults apply only to missing config/keys.
# Usage: $solution = Read-ScanConfigValue -Key 'languages.csharp.build.solution' -Default ''
function Read-ScanConfigValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [string]$Default = ''
    )

    $cfg = if ($env:SCAN_CONFIG_FILE) { $env:SCAN_CONFIG_FILE } else { 'scan-config.yaml' }
    if (-not (Test-Path $cfg)) { return $Default }

    $py = Find-WorkingPython
    if (-not $py) {
        [Console]::Error.WriteLine('[scan-config] ERROR: Python is required to read scan-config.yaml')
        exit 1
    }
    & $py -E -P "$PSScriptRoot/scan_config.py" $Key $cfg $Default |
        ForEach-Object { $_.ToString().Trim() }
    if ($LASTEXITCODE -ne 0) { exit 1 }
}

# Count Semgrep findings by severity from a --json output file (native parse).
# ERROR->High, WARNING->Medium, INFO->Low. Returns a hashtable @{High;Medium;Low;Total}.
function Get-SemgrepCounts {
    param([Parameter(Mandatory)][string]$JsonPath)
    $res = @{ High = 0; Medium = 0; Low = 0; Total = 0 }
    try {
        $doc = Get-Content $JsonPath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($null -eq $doc.results -or $doc.errors) { throw 'Incomplete scanner report' }
        foreach ($r in @($doc.results)) {
            switch (("" + $r.extra.severity).ToUpper()) {
                'ERROR'   { $res.High++ }
                'WARNING' { $res.Medium++ }
                default   { $res.Low++ }
            }
        }
        $res.Total = $res.High + $res.Medium + $res.Low
    } catch { throw }
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
        [string]$ToolPath,
        [Parameter(Mandatory)]
        [string[]]$ArgumentList
    )

    $diagnostics = New-TemporaryFile
    try {
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $output = & $ToolPath @ArgumentList 2> $diagnostics
            $exitCode = $LASTEXITCODE
            $stderr = [System.IO.File]::ReadAllText($diagnostics)
            if ($exitCode -ne 0 -and $stderr -match 'database.*locked|cache may be in use by another process') {
                if ($attempt -eq 1) {
                    Write-HookWarn 'Trivy database locked; retrying'
                    Start-Sleep -Seconds 2
                    continue
                }
                $exitCode = 2
            }
            return @{ Output = ($output -join "`n"); Stderr = $stderr; ExitCode = $exitCode }
        }
    } finally { Remove-Item -LiteralPath $diagnostics -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

function Test-ToolAvailable {
    param(
        [Parameter(Mandatory)]
        [string]$ToolName
    )

    if (-not (Get-Command $ToolName -CommandType Application -ErrorAction SilentlyContinue)) {
        if ($env:SCAN_ALLOW_TOOL_ERRORS -ne '1') { throw "$ToolName not found; scan incomplete" }
        Write-HookWarn "$ToolName unavailable; explicit local fail-open opt-in"
        return $false
    }
    # Return the verified path so callers never resolve the bare name again.
    return Resolve-VerifiedTool -Name $ToolName -Label $ToolName
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
