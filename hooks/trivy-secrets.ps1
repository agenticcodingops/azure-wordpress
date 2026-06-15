# trivy-secrets.ps1 — Trivy secret detection scanner
# Stage: pre-commit | Mode: scan ONLY staged file content | --skip-db-update
# Exports staged content to a temp directory so only changed files are scanned.
param([Parameter(ValueFromRemainingArguments)]$ExtraArgs)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"

# Verify tool availability
if (-not (Test-ToolAvailable 'trivy')) { exit 0 }

# Get list of staged files (all types — secrets can be in any file).
# Use -z (NUL-delimited) so filenames containing newlines are handled correctly.
$rawStaged = git diff --cached --name-only --diff-filter=ACMR -z 2>$null
$stagedFiles = @()
if ($rawStaged) {
    $stagedFiles = @(($rawStaged -join '') -split "`0" | Where-Object { $_ })
}
if (@($stagedFiles).Count -eq 0) {
    Write-HookLog "PASS: No files staged"
    exit 0
}

Start-ScanTimer

$stagedCount = @($stagedFiles).Count
Write-HookLog "Scanning... ($stagedCount staged files)"

# Create temp dir with ONLY staged file content — avoids scanning entire repo
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "trivy-secrets-$(Get-Random)"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

try {
    $skipped = 0
    foreach ($file in @($stagedFiles)) {
        # Create parent directories in temp
        $fileDir = Split-Path $file -Parent
        if ($fileDir) {
            $targetDir = Join-Path $tmpDir $fileDir
            if (-not (Test-Path -LiteralPath $targetDir)) {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            }
        }
        # Export staged content (from git index, not working tree). Capture git's
        # raw stdout BYTES via a Process so binary blobs are preserved verbatim —
        # a `git show | Set-Content` pipeline decodes to text first and corrupts
        # binary content (and -NoNewline would strip trailing newlines).
        $targetFile = Join-Path $tmpDir $file
        try {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = 'git'
            $psi.Arguments = "show `":$file`""
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            $ms = [System.IO.MemoryStream]::new()
            $exitCode = -1
            try {
                # Drain stderr ASYNCHRONOUSLY while we synchronously copy stdout.
                # Both pipes are redirected; reading only stdout would let a noisy
                # stderr fill its buffer, block git, and deadlock WaitForExit()
                # (the classic two-pipe deadlock).
                $errTask = $proc.StandardError.ReadToEndAsync()
                $proc.StandardOutput.BaseStream.CopyTo($ms)
                $null = $errTask.GetAwaiter().GetResult()
                $proc.WaitForExit()
                $bytes = $ms.ToArray()
                # Capture ExitCode BEFORE the finally disposes $proc — accessing
                # ExitCode after Dispose() can throw InvalidOperationException.
                $exitCode = $proc.ExitCode
            } finally {
                $ms.Dispose()
                $proc.Dispose()
            }
            if ($exitCode -ne 0) { throw "git show exit $exitCode" }
            [System.IO.File]::WriteAllBytes($targetFile, $bytes)
        } catch {
            # Export failure (binary/encoding/etc.) -> count + surface so secret-scan
            # coverage gaps are visible rather than silently dropped.
            $skipped++
            Write-HookWarn "could not export staged '$file' for secret scan (skipped)"
        }
    }
    if ($skipped -gt 0) { Write-HookWarn "$skipped staged file(s) skipped from the secret scan" }

    # Build Trivy command — scan the temp dir (contains only staged files)
    $trivyArgs = @('fs', $tmpDir, '--scanners', 'secret', '--exit-code', '1', '--format', 'json', '--skip-db-update', '--quiet')

    # Add extra args
    if ($ExtraArgs) {
        $trivyArgs += $ExtraArgs
    }

    # Run Trivy with retry
    $result = Invoke-TrivyWithRetry -ArgumentList $trivyArgs

    $totalCritical = 0
    $totalHigh = 0
    $totalMedium = 0
    $totalLow = 0

    if ($result.ExitCode -eq 1) {
        # Parse findings
        try {
            $json = $result.Output | ConvertFrom-Json
            $secrets = $json.Results | ForEach-Object { $_.Secrets } | Where-Object { $_ }
            $totalCritical = @($secrets | Where-Object { $_.Severity -eq 'CRITICAL' }).Count
            $totalHigh = @($secrets | Where-Object { $_.Severity -eq 'HIGH' }).Count
            $totalMedium = @($secrets | Where-Object { $_.Severity -eq 'MEDIUM' }).Count
            $totalLow = @($secrets | Where-Object { $_.Severity -eq 'LOW' }).Count
        } catch {
            $totalHigh = 1
        }
        # Show actionable details so developers know what to fix
        Show-TrivySecretFindings -JsonOutput $result.Output
        $exitCode = 1
    } elseif ($result.ExitCode -ge 2) {
        # Infrastructure error — fail-open
        $null = Get-HookExitCode -ToolExitCode $result.ExitCode
        $exitCode = 0
    } else {
        $exitCode = 0
    }
} finally {
    # Clean up temp directory
    if (Test-Path -LiteralPath $tmpDir) {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$durationMs = Stop-ScanTimer

if ($exitCode -eq 0) {
    Write-HookLog "PASS: No findings above threshold"
    Write-ScanJson (Build-PassJson -Tool 'trivy' -DurationMs $durationMs)
} else {
    Write-HookLog "FAIL: $(Format-FindingSummary -Critical $totalCritical -High $totalHigh -Medium $totalMedium -Low $totalLow)"
    Write-ScanJson (Build-FindingsJson -Tool 'trivy' -DurationMs $durationMs -Critical $totalCritical -High $totalHigh -Medium $totalMedium -Low $totalLow)
}

exit $exitCode
