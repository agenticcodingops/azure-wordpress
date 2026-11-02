# gitleaks.ps1 — Gitleaks secret detection scanner
# Stage: pre-commit | Severity: HIGH (all secrets map to HIGH)
# Scans ONLY staged changes. `git --staged` is the supported form of the
# deprecated `protect --staged` command (hidden since Gitleaks 8.19.0).
# The JSON report is stdout (`--report-path -`). stderr is not part of the report.
# Do NOT print Match or Secret: those fields are the credential.
param([Parameter(ValueFromRemainingArguments)]$ExtraArgs)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\common.ps1"

# A config error is text on stderr. PowerShell 7.4+ would otherwise turn that
# native stderr into a terminating error and hide the exit code.
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

# Verify tool availability
if (-not (Test-ToolAvailable 'gitleaks')) { exit 0 }

# Check if there are any staged files at all
$stagedFiles = git diff --cached --name-only --diff-filter=ACMR 2>$null
if (-not $stagedFiles -or @($stagedFiles).Count -eq 0) {
    Write-HookLog "PASS: No files staged"
    exit 0
}

Start-ScanTimer

$stagedCount = @($stagedFiles).Count
Write-HookLog "Scanning... ($stagedCount staged files)"

# `git --staged` with `--report-path -` writes the JSON array to stdout.
# `protect --staged` without `--report-path` writes no JSON, and Gitleaks uses
# exit 1 both for leaks and for a config it cannot load.
$gitleaksArgs = @(
    'git', '--staged',
    '--report-format', 'json',
    '--report-path', '-',
    '--redact',
    '--no-banner',
    '--exit-code', '1',
    '--log-level', 'error'
)

# Check for config file
$configFile = Resolve-ScanConfig -Filename '.gitleaks.toml'
if ($configFile) {
    $gitleaksArgs += @('--config', $configFile)
}

# Add extra args
if ($ExtraArgs) {
    $gitleaksArgs += $ExtraArgs
}

$stderrFile = New-TemporaryFile
try {
    $stdout = & gitleaks @gitleaksArgs 2>$stderrFile
    $exitCode = $LASTEXITCODE
} finally {
    Remove-Item -Force $stderrFile -ErrorAction SilentlyContinue
}

function ConvertFrom-GitleaksReport {
    param([string]$ReportText)

    if ([string]::IsNullOrWhiteSpace($ReportText)) {
        return @{ Ok = $false; Unparsed = $false; Rows = @() }
    }
    $trim = $ReportText.Trim()
    if (-not $trim.StartsWith('[')) {
        return @{ Ok = $false; Unparsed = $false; Rows = @() }
    }
    # ConvertFrom-Json accepts truncated JSON. System.Text.Json does not, and
    # a truncated findings array must not become a pass. Never read Secret or Match.
    # Windows PowerShell 5.1 has no System.Text.Json; fall back there.
    if (-not ('System.Text.Json.JsonDocument' -as [type])) {
        try {
            if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('NoEnumerate')) {
                $data = $trim | ConvertFrom-Json -NoEnumerate -ErrorAction Stop
            } else {
                $data = $trim | ConvertFrom-Json -ErrorAction Stop
            }
        } catch {
            $compact = [regex]::Replace($trim, '\s', '')
            $unparsed = $compact.StartsWith('[') -and $compact -ne '[]'
            return @{ Ok = $false; Unparsed = $unparsed; Rows = @() }
        }
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($item in @($data)) {
            if ($null -eq $item -or -not $item.RuleID) { continue }
            $start = 0
            if ($null -ne $item.StartLine) { $start = [int]$item.StartLine }
            $end = $start
            if ($null -ne $item.EndLine) { $end = [int]$item.EndLine }
            $desc = ''
            if ($null -ne $item.Description) { $desc = [string]$item.Description }
            $path = ''
            if ($null -ne $item.File) { $path = [string]$item.File }
            $rows.Add([pscustomobject]@{
                RuleId      = [string]$item.RuleID
                File        = $path
                Start       = $start
                End         = $end
                Description = $desc
            }) | Out-Null
        }
        return @{ Ok = $true; Unparsed = $false; Rows = $rows }
    }
    $doc = $null
    try {
        $doc = [System.Text.Json.JsonDocument]::Parse($trim)
    } catch {
        $compact = [regex]::Replace($trim, '\s', '')
        $unparsed = $compact.StartsWith('[') -and $compact -ne '[]'
        return @{ Ok = $false; Unparsed = $unparsed; Rows = @() }
    }

    try {
        if ($doc.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) {
            return @{ Ok = $false; Unparsed = $false; Rows = @() }
        }
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($item in $doc.RootElement.EnumerateArray()) {
            if ($item.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { continue }
            $rule = ''
            $path = ''
            $desc = ''
            $start = 0
            $end = 0
            foreach ($prop in $item.EnumerateObject()) {
                if ($prop.Name -eq 'RuleID' -and $prop.Value.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
                    $rule = $prop.Value.GetString()
                } elseif ($prop.Name -eq 'File' -and $prop.Value.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
                    $path = $prop.Value.GetString()
                } elseif ($prop.Name -eq 'Description' -and $prop.Value.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
                    $desc = $prop.Value.GetString()
                } elseif ($prop.Name -eq 'StartLine' -and $prop.Value.ValueKind -eq [System.Text.Json.JsonValueKind]::Number) {
                    $start = $prop.Value.GetInt32()
                } elseif ($prop.Name -eq 'EndLine' -and $prop.Value.ValueKind -eq [System.Text.Json.JsonValueKind]::Number) {
                    $end = $prop.Value.GetInt32()
                }
            }
            if (-not $rule) { continue }
            if ($end -eq 0) { $end = $start }
            $rows.Add([pscustomobject]@{
                RuleId      = $rule
                File        = $path
                Start       = $start
                End         = $end
                Description = $desc
            }) | Out-Null
        }
        return @{ Ok = $true; Unparsed = $false; Rows = $rows }
    } finally {
        if ($null -ne $doc) { $doc.Dispose() }
    }
}

function Write-GitleaksPass {
    param([int]$DurationMs)
    Write-HookLog "PASS: No findings above threshold"
    Write-ScanJson (Build-PassJson -Tool 'gitleaks' -DurationMs $DurationMs)
}

$text = ''
if ($null -ne $stdout) {
    $text = (@($stdout) -join "`n").Trim()
}
$parsed = ConvertFrom-GitleaksReport -ReportText $text

# A non-array report is a tool failure. Gitleaks uses exit 1 for a config it
# cannot load, so that exit alone cannot mean "finding". pre-commit blocks
# every non-zero status, so fail-open is a warning and process exit 0.
# An array-shaped report that cannot be parsed is different: the scan wrote
# findings and failing open would allow them. Block, and do not print the
# report. The bash hook does the same when neither Python nor jq is installed.
if (-not $parsed.Ok) {
    if ($parsed.Unparsed) {
        $durationMs = Stop-ScanTimer
        $unparsedMessage = 'Gitleaks wrote a JSON findings report that could not be parsed, so rule, file, and line were not read. The report was not printed.'
        Write-HookWarn 'gitleaks wrote a JSON findings report that could not be parsed. The commit is blocked and the report was not printed.'
        Write-HookLog ''
        Write-HookLog '  HIGH  gitleaks-report-unparsed  .:0-0'
        Write-HookLog "    $unparsedMessage"
        Write-HookLog ''
        Write-HookLog "FAIL: $(Format-FindingSummary -High 1)"
        $findingsJson = '[{"rule_id":"gitleaks-report-unparsed","tool":"gitleaks","severity":"HIGH","file":".","line":0,"message":"' + $unparsedMessage + '","fixable":false,"fixed":false}]'
        Write-ScanJson (Build-FindingsJson -Tool 'gitleaks' -DurationMs $durationMs -FindingsArray $findingsJson -High 1)
        exit 1
    }
    Write-HookWarn "gitleaks exited $exitCode without a JSON findings report - allowing commit (fail-open)"
    Write-GitleaksPass -DurationMs (Stop-ScanTimer)
    exit 0
}

$rows = @($parsed.Rows | Where-Object { $null -ne $_ })
$durationMs = Stop-ScanTimer
if ($rows.Count -eq 0) {
    Write-GitleaksPass -DurationMs $durationMs
    exit 0
}

Write-HookLog ""
foreach ($row in $rows) {
    Write-HookLog "  HIGH  $($row.RuleId)  $($row.File):$($row.Start)-$($row.End)"
    if ($row.Description) {
        Write-HookLog "    $($row.Description)"
    }
}
Write-HookLog ""
Write-HookLog "FAIL: $(Format-FindingSummary -High $rows.Count)"

$findingObjects = foreach ($row in $rows) {
    [pscustomobject]@{
        rule_id  = $row.RuleId
        tool     = 'gitleaks'
        severity = 'HIGH'
        file     = $row.File
        line     = $row.Start
        message  = $row.Description
        fixable  = $false
        fixed    = $false
    }
}
$findingsJson = ConvertTo-Json -InputObject @($findingObjects) -Depth 5 -Compress
if ($rows.Count -eq 1 -and -not $findingsJson.TrimStart().StartsWith('[')) {
    $findingsJson = '[' + $findingsJson + ']'
}
Write-ScanJson (Build-FindingsJson -Tool 'gitleaks' -DurationMs $durationMs -FindingsArray $findingsJson -High $rows.Count)
exit 1
