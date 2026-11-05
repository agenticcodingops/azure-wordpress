# Canonical setup identities shared by onboarding and hook verification.
function Resolve-SetupRealPath {
    param([string]$Path, [switch]$PreserveLinks)
    $full = if ($PreserveLinks) { [IO.Path]::GetFullPath($Path) } else { Resolve-ExternalRealPath $Path }
    if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
        if (-not ('SetupPathNative' -as [type])) {
            Add-Type @'
using System.Runtime.InteropServices;
using System.Text;
public static class SetupPathNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetLongPathName(string path, StringBuilder output, uint size);
}
'@
        }
        $buffer = [Text.StringBuilder]::new(32768)
        $length = [SetupPathNative]::GetLongPathName($full, $buffer, $buffer.Capacity)
        if (-not $length -or $length -ge $buffer.Capacity) {
            throw 'Cannot canonicalize setup path'
        }
        $full = $buffer.ToString()
        if ($full.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
            $full = '\\' + $full.Substring(8)
        } elseif ($full.StartsWith('\\?\')) {
            $full = $full.Substring(4)
        }
    }
    return $full
}

function Get-ToolCheckoutRoot {
    param([string]$Directory)
    # Windows PowerShell turns native stderr into terminating errors under Stop,
    # even when redirected. A failed Git discovery must retain the cwd boundary.
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $root = git -C $Directory rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0) { return $root }
}

function Resolve-VerifiedTool {
    # Resolve a tool by name and refuse one that lives inside the scanned or consumer
    # checkout, so a repository cannot shadow it on PATH. Check both the invoked
    # location and target, but retain external virtual environments' original paths.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Label,
        [string[]]$AdditionalRoots = @()
    )
    $path = (Get-Command $Name -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    if (-not [IO.Path]::IsPathRooted($path)) { throw "$Label must resolve to an absolute executable path" }
    # Python can load pyvenv.cfg and startup files relative to the invoked path.
    # Keep the final link unresolved when checking that environment's directory.
    $invoked = Join-Path (Resolve-SetupRealPath ([IO.Path]::GetDirectoryName($path))) ([IO.Path]::GetFileName($path))
    $canonical = $null
    $unresolved = $null
    try { $canonical = Resolve-SetupRealPath $path }
    catch {
        if ($_.FullyQualifiedErrorId -notlike 'UnresolvableTrustedPathLink*') { throw }
        $unresolved = $_
    }
    $identities = @((Resolve-SetupRealPath $path -PreserveLinks), $invoked)
    if ($canonical) { $identities += $canonical }
    $snapshot = $env:SCAN_PUSH_SNAPSHOT -eq '1' -or $env:SCAN_INDEX_SNAPSHOT -eq '1'
    $repoRoot = if ($snapshot) { (Get-Location).Path } else {
        Assert-GitAvailable
        Get-ToolCheckoutRoot (Get-Location).Path
    }
    if (-not $repoRoot) { $repoRoot = (Get-Location).Path }
    $roots = @($repoRoot)
    foreach ($directory in $AdditionalRoots) {
        # PowerShell's location can differ from the process working directory.
        $directory = Resolve-HookPath $directory
        $roots += $directory
        # A module can live in a separate checkout: its sibling bin directory
        # is just as untrusted as an executable directly beneath the module.
        $checkout = Get-ToolCheckoutRoot $directory
        if ($checkout) { $roots += $checkout }
    }
    if ($snapshot -and $env:SCAN_CONSUMER_ROOT) { $roots += $env:SCAN_CONSUMER_ROOT }
    $comparison = if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
        [StringComparison]::OrdinalIgnoreCase
    } else { [StringComparison]::Ordinal }
    foreach ($root in $roots) {
        $boundaries = @((Resolve-SetupRealPath $root), (Resolve-SetupRealPath $root -PreserveLinks))
        foreach ($boundary in $boundaries) {
            $boundary = $boundary.TrimEnd('/', '\')
            foreach ($identity in $identities) {
                if ($identity.Equals($boundary, $comparison) -or $identity.StartsWith($boundary + [IO.Path]::DirectorySeparatorChar, $comparison)) {
                    throw "$Label must resolve outside the scanned and consumer checkouts"
                }
            }
        }
    }
    # An opaque target is never executed. Check its known identities first so an
    # in-checkout alias cannot turn a boundary rejection into a fallback.
    if ($unresolved) { throw $unresolved }
    return $path
}

function Resolve-VerifiedPython {
    param([string]$Name, [string[]]$AdditionalRoots = @())
    $path = Resolve-VerifiedTool -Name $Name -Label Python -AdditionalRoots $AdditionalRoots
    if ($Name -eq 'py' -and [Environment]::OSVersion.Platform -eq 'Win32NT') {
        # With no version selector the Windows launcher prefers VIRTUAL_ENV.
        # Never use a Python probe through the launcher: it can delegate to an
        # unchecked interpreter. The inventory command lists paths without running
        # Python and marks the configured default with an asterisk.
        if ($env:VIRTUAL_ENV) {
            $environment = Resolve-HookPath $env:VIRTUAL_ENV
            $interpreter = Join-Path $environment 'Scripts/python.exe'
        } else {
            $listing = & $path -0p 2>$null
            if ($LASTEXITCODE -ne 0) { throw 'Cannot verify py selection; put python or python3 on PATH' }
            $defaults = @($listing | ForEach-Object {
                if ([string]$_ -match '^\s*-\S+\s+\*\s+(.+?)\s*$') { $Matches[1].Trim('"') }
            })
            if ($defaults.Count -ne 1) { throw 'Cannot verify py selection; put python or python3 on PATH' }
            $interpreter = $defaults[0]
        }
        if (-not (Test-Path -LiteralPath $interpreter -PathType Leaf)) {
            throw 'Cannot verify py virtual environment; put python or python3 on PATH'
        }
        $path = Resolve-VerifiedTool -Name $interpreter -Label Python -AdditionalRoots $AdditionalRoots
    }
    return $path
}
