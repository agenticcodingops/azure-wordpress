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
    $identities = @((Resolve-SetupRealPath $path), (Resolve-SetupRealPath $path -PreserveLinks), $invoked)
    $snapshot = $env:SCAN_PUSH_SNAPSHOT -eq '1' -or $env:SCAN_INDEX_SNAPSHOT -eq '1'
    $repoRoot = if ($snapshot) { (Get-Location).Path } else {
        Assert-GitAvailable
        git rev-parse --show-toplevel 2>$null
    }
    if (-not $repoRoot) { $repoRoot = (Get-Location).Path }
    $roots = @($repoRoot)
    foreach ($directory in $AdditionalRoots) {
        # PowerShell's location can differ from the process working directory.
        $directory = Resolve-HookPath $directory
        $roots += $directory
        # A module can live in a separate checkout: its sibling bin directory
        # is just as untrusted as an executable directly beneath the module.
        $checkout = git -C $directory rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and $checkout) { $roots += $checkout }
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
    return $path
}
