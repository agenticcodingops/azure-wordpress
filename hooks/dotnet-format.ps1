# dotnet-format.ps1 — .NET formatting check (dotnet format --verify-no-changes)
# Stage: pre-commit | Mode: staged .cs only
#
# Solution + working dir come from scan-config.yaml (languages.csharp.build.*),
# never hardcoded — the generic fix for the api/ path bug. Empty solution =>
# auto-detect nearest .slnx/.sln under the working dir.
param([Parameter(ValueFromRemainingArguments)]$ExtraArgs)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"

if (-not (Test-ToolAvailable 'dotnet')) { exit 0 }

$allCs = Get-StagedFiles -Extensions @('cs')
if (@($allCs).Count -eq 0) {
    Write-HookLog "PASS: No C# files staged"
    exit 0
}

$workingDir = Read-ScanConfigValue -Key 'languages.csharp.build.working_dir' -Default '.'
$solution = Read-ScanConfigValue -Key 'languages.csharp.build.solution' -Default ''

# Strip a leading './' or '.\' only — it breaks the staged-file prefix match below.
# Anchored + single-segment so a legitimate working_dir ('.', '.config', '../x') is
# left intact.
$workingDir = $workingDir -replace '^\.[/\\]', ''

# Filter staged files to those under working_dir; make relative to it.
$wdPrefix = ($workingDir.TrimEnd('/', '\') + '/')
$includeFiles = @()
foreach ($f in $allCs) {
    $norm = $f -replace '\\', '/'
    if ($workingDir -eq '.') {
        $includeFiles += $norm
    } elseif ($norm.StartsWith($wdPrefix)) {
        $includeFiles += $norm.Substring($wdPrefix.Length)
    }
}
if ($includeFiles.Count -eq 0) {
    Write-HookLog "PASS: No staged C# files under working_dir '$workingDir'"
    exit 0
}

if (-not $solution) {
    $solution = Find-DotnetSolution -WorkingDir $workingDir
    if ($solution -and $workingDir -ne '.') {
        $full = (Resolve-Path $workingDir -ErrorAction SilentlyContinue).Path
        if ($full) { $solution = $solution.Replace($full, '').TrimStart('/', '\') }
    }
}
if (-not $solution) {
    Write-HookWarn "No .sln/.slnx found under '$workingDir' (set languages.csharp.build.solution) - allowing commit"
    exit 0
}

Start-ScanTimer
Write-HookLog "Checking format... ($($includeFiles.Count) files, $solution in $workingDir)"

$formatArgs = @('format', $solution, '--verify-no-changes', '--no-restore')
foreach ($inc in $includeFiles) { $formatArgs += @('--include', $inc) }
if ($ExtraArgs) { $formatArgs += $ExtraArgs }

Push-Location $workingDir
try {
    $output = & dotnet @formatArgs 2>&1
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
}
$durationMs = Stop-ScanTimer

if ($exitCode -eq 0) {
    Write-HookLog "PASS: Formatting OK (${durationMs}ms)"
    Write-ScanJson (Build-PassJson -Tool 'dotnet-format' -ScanDirectory $workingDir -DurationMs $durationMs)
    exit 0
} else {
    $output | ForEach-Object { Write-Host $_ }
    Write-HookLog "FAIL: Formatting needed — run 'dotnet format $solution' in $workingDir"
    Write-ScanJson (Build-FindingsJson -Tool 'dotnet-format' -ScanDirectory $workingDir -DurationMs $durationMs -Medium 1)
    exit 1
}
