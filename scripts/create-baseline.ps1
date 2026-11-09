<#
.SYNOPSIS
    Creates a baseline snapshot of current scan findings for new-only reporting.

.DESCRIPTION
    Creates a baseline of current security scan findings so subsequent scans
    report only NEW findings. This enables teams adopting scanning on existing
    codebases to focus on preventing new issues while gradually addressing debt.

    Schema 2.0 uses occurrence_fingerprint: tool, rule, repository-relative path,
    resource, line range and the file-content SHA-256 hash. Any content change
    in that file invalidates its entries, requiring renewed approval.

    Output conforms to the Baseline entity schema in data-model.md.

.PARAMETER Tool
    Which scanning tool to baseline. Default: all

.PARAMETER OutputDir
    Directory to store baseline files. Default: .scan-baseline at the repository
    root. Explicit relative paths are resolved from the invocation directory.

.PARAMETER TerraformDir
    Directory containing Terraform code to scan. Default: .

.PARAMETER CloudProvider
    Cloud provider for context. Default: auto-detected.

.PARAMETER MonorepoScope
    Scope baseline to specific Terraform modules/directories (comma-separated).
    Example: "terraform/modules/networking,terraform/modules/compute"

.PARAMETER Force
    Overwrite existing baseline without prompting.

.PARAMETER PolicyRoot
    Separate trusted base checkout outside the scanned repository, used by the
    gate to approve inline skips.

.PARAMETER BaseCommit
    Explicit trusted base commit used when a separate policy checkout is unavailable.
    Without either trusted input, local remote-default policy selection is retained.

.EXAMPLE
    .\create-baseline.ps1
    Creates baseline for all tools in the current directory.

.EXAMPLE
    .\create-baseline.ps1 -Tool trivy -CloudProvider aws -Force
    Creates Trivy-only baseline with AWS context, overwriting existing.

.EXAMPLE
    .\create-baseline.ps1 -MonorepoScope "terraform/networking,terraform/compute"
    Creates scoped baseline for specific monorepo modules.

.NOTES
    Part of auto-code-scanning infrastructure.
    Each schema 2.0 entry approves one exact occurrence_fingerprint.
    Staleness warning at 90 days per FR-072.
#>

[CmdletBinding()]
param(
    [ValidateSet("trivy", "checkov", "tflint", "all")]
    [string]$Tool = "all",

    [string]$OutputDir = ".scan-baseline",

    [string]$TerraformDir = ".",

    [ValidateSet("aws", "azure", "gcp", "")]
    [string]$CloudProvider = "",

    [string]$MonorepoScope = "",

    [ValidateNotNullOrEmpty()]
    [string]$PolicyRoot,

    [ValidateNotNullOrEmpty()]
    [string]$BaseCommit,

    [switch]$Force
)

$ErrorActionPreference = "Stop"

if ($PolicyRoot -and $BaseCommit) { throw 'Supply either PolicyRoot or BaseCommit, not both' }

. "$PSScriptRoot/../hooks/lib/common.ps1"
$sourceRoot = git rev-parse --show-toplevel
if ($LASTEXITCODE -ne 0) { $sourceRoot = (Get-Location).Path }
if ($PolicyRoot) {
    $PolicyRoot = Resolve-ExternalRealPath (Resolve-Path -LiteralPath $PolicyRoot -ErrorAction Stop).Path
    Assert-ExternalPath $PolicyRoot
    if (-not (Test-Path -LiteralPath $PolicyRoot -PathType Container)) { throw 'PolicyRoot must be a trusted external checkout directory' }
}
if ($BaseCommit) {
    $resolvedBase = git -C $sourceRoot rev-parse --verify --end-of-options "${BaseCommit}^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0 -or $resolvedBase -notmatch '^([0-9a-f]{40}|[0-9a-f]{64})$') {
        throw 'BaseCommit must identify an existing commit'
    }
    $BaseCommit = $resolvedBase.Trim()
}
if (-not $PSBoundParameters.ContainsKey('OutputDir')) {
    $OutputDir = Join-Path $sourceRoot '.scan-baseline'
}
Assert-SafeTree $OutputDir

# Create output directory
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
$dateStamp = Get-Date -Format "yyyy-MM-dd"

# Detect cloud provider if not specified
if (-not $CloudProvider) {
    if (Test-Path ".scanning/configs/.checkov.yaml") {
        $configContent = Get-Content ".scanning/configs/.checkov.yaml" -Raw -ErrorAction SilentlyContinue
        if ($configContent -match "aws") { $CloudProvider = "aws" }
        elseif ($configContent -match "azure") { $CloudProvider = "azure" }
        elseif ($configContent -match "gcp") { $CloudProvider = "gcp" }
    }
    if (-not $CloudProvider) { $CloudProvider = "unknown" }
}

# Parse monorepo scope
$scopedDirs = @()
if ($MonorepoScope) {
    $scopedDirs = $MonorepoScope -split "," | ForEach-Object { $_.Trim() }
}

# Initialize baseline structure per data-model.md Baseline entity
$baseline = @{
    schema_version = "2.0"
    scan_directory = $TerraformDir
    created_date = $timestamp
    created_by = "create-baseline.ps1"
    cloud_provider = $CloudProvider
    scoped_directories = $scopedDirs
    entries = @()
    checkov_reports = @()
    scanner_reports = @()
}

function Find-BaselinePython {
    # Verify before probing: even a version/capability probe executes the tool.
    $scanDirs = if ($scopedDirs.Count -gt 0) { $scopedDirs } else { @($TerraformDir) }
    foreach ($name in @('python', 'python3', 'py')) {
        if (-not (Get-Command $name -CommandType Application -ErrorAction SilentlyContinue)) { continue }
        try { $candidate = Resolve-VerifiedPython -Name $name -AdditionalRoots (@($sourceRoot) + $scanDirs) }
        catch {
            # The resolver checks lexical and invoked identities before
            # returning this error. Only opaque external aliases may skip.
            if ($_.FullyQualifiedErrorId -like 'UnresolvableTrustedPathLink*') { continue }
            throw
        }
        try {
            & $candidate -E -P -c 'pass' 2>$null
            if ($LASTEXITCODE -eq 0) { return $candidate }
        } catch { }
    }
    throw 'Baseline creation requires Python 3.11 or later'
}

function New-TrivyBaseline {
    Write-Host "Creating Trivy baseline..." -ForegroundColor Cyan

    if (-not (Get-Command trivy -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Warning "Trivy not found. Skipping Trivy baseline."
        return @()
    }

    $scanDirs = if ($scopedDirs.Count -gt 0) { $scopedDirs } else { @($TerraformDir) }
    $scanner = Resolve-VerifiedTool -Name trivy -Label trivy -AdditionalRoots (@($sourceRoot) + $scanDirs)
    $entries = @()

    foreach ($dir in $scanDirs) {
        $trivyJson = & $scanner config --severity CRITICAL,HIGH,MEDIUM,LOW --include-non-failures --format json --quiet -- $dir 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Trivy scan failed for $dir (exit $LASTEXITCODE)" }
        if (-not $trivyJson) { throw "Trivy returned no report for $dir" }
        if ($trivyJson) {
            try {
                $trivyResults = $trivyJson | ConvertFrom-Json
                $baseline.scanner_reports += @{ tool = 'trivy'; report = $trivyResults }
                foreach ($result in $trivyResults.Results) {
                    foreach ($misconfig in $result.Misconfigurations) {
                        if ($misconfig.Status -eq 'PASS') { continue }
                        $ruleId = $misconfig.AVDID ?? $misconfig.ID
                        $filePath = $result.Target
                        $entries += @{
                            rule_id = $ruleId
                            file = $filePath
                            scan_directory = $dir
                            line = $misconfig.CauseMetadata.StartLine
                            end_line = $misconfig.CauseMetadata.EndLine
                            resource = $misconfig.CauseMetadata.Resource
                            tool = "trivy"
                            severity = $misconfig.Severity
                            baselined_date = $dateStamp
                        }
                    }
                }
            }
            catch {
                throw "Failed to parse Trivy JSON output for scan path '$dir' while creating '$metadataFile'"
            }
        }
    }

    Write-Host "  Trivy: $($entries.Count) findings baselined" -ForegroundColor Gray
    return $entries
}

function New-CheckovBaseline {
    Write-Host "Creating Checkov baseline..." -ForegroundColor Cyan

    if (-not (Get-Command checkov -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Warning "Checkov not found. Skipping Checkov baseline."
        return @()
    }

    $scanDirs = if ($scopedDirs.Count -gt 0) { $scopedDirs } else { @($TerraformDir) }
    $scanner = Resolve-VerifiedTool -Name checkov -Label checkov -AdditionalRoots (@($sourceRoot) + $scanDirs)
    $entries = @()

    $policyFile = New-TemporaryFile
    try {
        Assert-SafeWritePath $policyFile
        $source = Resolve-ScanConfig -Filename '.checkov.yaml'
        $policy = & $python -E -P "$PSScriptRoot/../hooks/lib/checkov_policy.py" $source
        if ($LASTEXITCODE -ne 0) { throw 'Checkov policy rejected; scan incomplete' }
        [IO.File]::WriteAllText($policyFile, ($policy -join "`n"))
        foreach ($dir in $scanDirs) {
            $checkovJson = & $scanner -d $dir --framework terraform --output json --compact --config-file $policyFile 2>$null
            if ($LASTEXITCODE -notin @(0, 1)) { throw "Checkov scan failed for $dir (exit $LASTEXITCODE)" }
            if (-not $checkovJson) { throw "Checkov returned no report for $dir" }
            try { $checkovResults = ($checkovJson -join "`n") | ConvertFrom-Json }
            catch {
                throw "Failed to parse Checkov JSON output for scan path '$dir' while creating '$metadataFile'"
            }
            $baseline.checkov_reports += @{
                scan_directory = Resolve-HookPath $dir
                report = $checkovResults
                baselined_date = $dateStamp
            }
        }
    } finally {
        Remove-Item -LiteralPath $policyFile -Force
    }

    Write-Host "  Checkov: report collected for shared gate normalization" -ForegroundColor Gray
    return $entries
}

function New-TflintBaseline {
    Write-Host "Creating tflint baseline..." -ForegroundColor Cyan

    if (-not (Get-Command tflint -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Warning "tflint not found. Skipping tflint baseline."
        return @()
    }

    if (-not $env:SCAN_TFLINT_CONFIG -or -not (Test-Path -LiteralPath $env:SCAN_TFLINT_CONFIG -PathType Leaf)) {
        if ($Tool -eq 'all' -and -not $env:SCAN_TFLINT_CONFIG) {
            Write-Warning 'SCAN_TFLINT_CONFIG is unset. Skipping tflint baseline.'
            return @()
        }
        throw 'SCAN_TFLINT_CONFIG must name a trusted external config'
    }
    Assert-TrustedTflintConfig $env:SCAN_TFLINT_CONFIG
    if (-not $env:SCAN_TFLINT_PLUGIN_DIR) { throw 'Set SCAN_TFLINT_PLUGIN_DIR to an external plugin cache' }
    Assert-ExternalPath $env:SCAN_TFLINT_PLUGIN_DIR
    Assert-SafeWritePath $env:SCAN_TFLINT_PLUGIN_DIR
    $env:TFLINT_PLUGIN_DIR = Resolve-ExternalRealPath $env:SCAN_TFLINT_PLUGIN_DIR
    $trustedConfig = Resolve-ExternalRealPath $env:SCAN_TFLINT_CONFIG

    $scanDirs = if ($scopedDirs.Count -gt 0) { $scopedDirs } else { @($TerraformDir) }
    $scanner = Resolve-VerifiedTool -Name tflint -Label tflint -AdditionalRoots (@($sourceRoot) + $scanDirs)
    $entries = @()

    foreach ($dir in $scanDirs) {
        $tflintJson = & $scanner --config=$trustedConfig --chdir=$dir --format json 2>$null
        if ($LASTEXITCODE -notin @(0, 2)) { throw "tflint scan failed for $dir (exit $LASTEXITCODE)" }
        if (-not $tflintJson) { throw "tflint returned no report for $dir" }
        if ($tflintJson) {
            try {
                $tflintResults = $tflintJson | ConvertFrom-Json
                $baseline.scanner_reports += @{ tool = 'tflint'; report = $tflintResults }
                foreach ($issue in $tflintResults.issues) {
                    $ruleId = $issue.rule.name
                    $filePath = $issue.range.filename
                    $entries += @{
                        rule_id = $ruleId
                        file = $filePath
                        scan_directory = $dir
                        line = $issue.range.start.line
                        end_line = $issue.range.end.line
                        resource = ""
                        tool = "tflint"
                        severity = $issue.rule.severity
                        baselined_date = $dateStamp
                    }
                }
            }
            catch {
                throw "Failed to parse tflint JSON output for scan path '$dir' while creating '$metadataFile'"
            }
        }
    }

    Write-Host "  tflint: $($entries.Count) findings baselined" -ForegroundColor Gray
    return $entries
}

# Check for existing baseline
$metadataFile = Join-Path $OutputDir "baseline.json"
if ((Test-Path $metadataFile) -and -not $Force) {
    # Check staleness of existing baseline (90-day warning per FR-072)
    try {
        $existingBaseline = Get-Content $metadataFile -Raw | ConvertFrom-Json
        $createdDate = [DateTime]::Parse($existingBaseline.created_date)
        $daysOld = ((Get-Date) - $createdDate).Days
        if ($daysOld -gt 90) {
            Write-Warning "Existing baseline is $daysOld days old (>90 days). Consider refreshing with -Force."
        }
    }
    catch {}

    Write-Warning "Baseline already exists at $OutputDir. Use -Force to overwrite."
    exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor White
Write-Host " Creating Scan Baseline" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White
Write-Host " Cloud Provider: $CloudProvider" -ForegroundColor Gray
if ($scopedDirs.Count -gt 0) {
    Write-Host " Monorepo Scope: $($scopedDirs -join ', ')" -ForegroundColor Gray
}
Write-Host ""

# Collect baseline entries
# Keep the verified absolute interpreter for policy generation and finalization.
$python = Find-BaselinePython
$allEntries = @()

switch ($Tool) {
    "trivy"   { $allEntries += New-TrivyBaseline }
    "checkov" { $allEntries += New-CheckovBaseline }
    "tflint"  { $allEntries += New-TflintBaseline }
    "all" {
        $allEntries += New-TrivyBaseline
        $allEntries += New-CheckovBaseline
        $allEntries += New-TflintBaseline
    }
}

$baseline.entries = $allEntries

# Finalize occurrence fingerprints using the shared SHA-256 implementation.
# Do not deduplicate repeated occurrences: each approval has a bounded count.
# Scanner directories are relative to the invocation, while identities are
# repository-relative. Pass absolute contexts to the shared normalizer.
foreach ($entry in $allEntries) {
    $entry.scan_directory = Resolve-HookPath $entry.scan_directory
}
$baseline.scan_directory = Resolve-HookPath $TerraformDir
$pending = New-TemporaryFile
try {
    Assert-SafeWritePath $pending
    $baseline | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $pending -Encoding UTF8
    $trustedInputs = @()
    if ($PolicyRoot) { $trustedInputs += @('--policy-root', $PolicyRoot) }
    if ($BaseCommit) { $trustedInputs += @('--base-commit', $BaseCommit) }
    & $python "$PSScriptRoot/finalize_baseline.py" $pending $metadataFile $sourceRoot @trustedInputs
    if ($LASTEXITCODE -ne 0) { throw 'Baseline identity validation failed' }
} finally { Remove-Item -LiteralPath $pending -ErrorAction SilentlyContinue }
$dedupedEntries = @((Get-Content -LiteralPath $metadataFile -Raw | ConvertFrom-Json).entries)

# Summary
$bySeverity = @{ CRITICAL = 0; HIGH = 0; MEDIUM = 0; LOW = 0 }
foreach ($entry in $dedupedEntries) {
    $sev = $entry.severity.ToUpper()
    if ($bySeverity.ContainsKey($sev)) { $bySeverity[$sev]++ }
}

$byTool = @{}
foreach ($entry in $dedupedEntries) {
    $t = $entry.tool
    if (-not $byTool.ContainsKey($t)) { $byTool[$t] = 0 }
    $byTool[$t]++
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " Baseline Created Successfully" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Location: $metadataFile" -ForegroundColor White
Write-Host "  Total entries: $($dedupedEntries.Count)" -ForegroundColor White
Write-Host "  Created: $timestamp" -ForegroundColor White
Write-Host ""
Write-Host "  By Severity:" -ForegroundColor White
Write-Host "    CRITICAL: $($bySeverity.CRITICAL)" -ForegroundColor $(if ($bySeverity.CRITICAL -gt 0) { "Red" } else { "Gray" })
Write-Host "    HIGH:     $($bySeverity.HIGH)" -ForegroundColor $(if ($bySeverity.HIGH -gt 0) { "Yellow" } else { "Gray" })
Write-Host "    MEDIUM:   $($bySeverity.MEDIUM)" -ForegroundColor Gray
Write-Host "    LOW:      $($bySeverity.LOW)" -ForegroundColor Gray
Write-Host ""
Write-Host "  By Tool:" -ForegroundColor White
foreach ($t in $byTool.Keys) {
    Write-Host "    $t`: $($byTool[$t])" -ForegroundColor Gray
}
Write-Host ""
Write-Host "Schema 2.0 matches tool, rule, path, resource, line range and source content." -ForegroundColor Gray
Write-Host "Each entry covers one occurrence; source changes require renewed approval." -ForegroundColor Gray
Write-Host ""
Write-Host "Review this baseline within 90 days ($((Get-Date).AddDays(90).ToString('yyyy-MM-dd')))" -ForegroundColor Yellow
Write-Host "Use -Force to refresh the baseline when needed." -ForegroundColor Yellow
Write-Host ""
