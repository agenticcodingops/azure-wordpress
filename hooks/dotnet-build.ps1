# dotnet-build.ps1 — Roslyn analyzers via 'dotnet build'
# Stage: pre-push (slower) | Mode: build the configured solution
#
# Solution + working dir come from scan-config.yaml (languages.csharp.build.*).
param([Parameter(ValueFromRemainingArguments)]$ExtraArgs)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"

if (-not (Test-ToolAvailable 'dotnet')) { exit 0 }

$staged = Get-StagedFiles -Extensions @('cs', 'csproj')
if (@($staged).Count -eq 0) {
    Write-HookLog "PASS: No C# files staged"
    exit 0
}

$workingDir = Read-ScanConfigValue -Key 'languages.csharp.build.working_dir' -Default '.'
$solution = Read-ScanConfigValue -Key 'languages.csharp.build.solution' -Default ''
if (-not $solution) {
    $solution = Find-DotnetSolution -WorkingDir $workingDir
    if ($solution -and $workingDir -ne '.') {
        $full = (Resolve-Path $workingDir -ErrorAction SilentlyContinue).Path
        if ($full) { $solution = $solution.Replace($full, '').TrimStart('/', '\') }
    }
}
if (-not $solution) {
    Write-HookWarn "No .sln/.slnx found under '$workingDir' (set languages.csharp.build.solution) - allowing push"
    exit 0
}

Start-ScanTimer
Write-HookLog "Building (Roslyn analyzers)... ($solution in $workingDir)"

$buildArgs = @('build', $solution, '/p:AnalysisMode=AllEnabledByDefault', '--nologo')
if ($ExtraArgs) { $buildArgs += $ExtraArgs }

Push-Location $workingDir
try {
    $output = & dotnet @buildArgs 2>&1
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
}
$durationMs = Stop-ScanTimer

if ($exitCode -eq 0) {
    Write-HookLog "PASS: Build + analyzers clean (${durationMs}ms)"
    Write-ScanJson (Build-PassJson -Tool 'dotnet-build' -ScanDirectory $workingDir -DurationMs $durationMs)
    exit 0
} else {
    $output | Where-Object { $_ -match 'error|warning' } | Select-Object -First 40 | ForEach-Object { Write-Host $_ }
    Write-HookLog "FAIL: Build/analyzer errors"
    Write-ScanJson (Build-FindingsJson -Tool 'dotnet-build' -ScanDirectory $workingDir -DurationMs $durationMs -High 1)
    exit 1
}
