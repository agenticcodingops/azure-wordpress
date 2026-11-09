#!/usr/bin/env bash
# common.sh — Shared bash functions for hook scripts
# Sourced by all .sh hook wrappers via:
#   source "${SCRIPT_DIR}/lib/common.sh"

# Guard against double-sourcing
[[ -n "${_COMMON_SH_LOADED:-}" ]] && return 0

# The library needs Bash 4.4+ (mapfile -d, ${var,,}). Check before anything newer is
# parsed, so an older shell (macOS /bin/bash is 3.2) stops with a clear message.
_scan_bash_supported() {
    local major="${1:-${BASH_VERSINFO[0]}}" minor="${2:-${BASH_VERSINFO[1]}}"
    (( major > 4 || (major == 4 && minor >= 4) ))
}
if ! _scan_bash_supported; then
    printf '[%s] ERROR: Bash 4.4 or later is required (found %s). On macOS: brew install bash and put it first on PATH\n' \
        "${SCAN_HOOK_ID:-hook}" "${BASH_VERSION:-unknown}" >&2
    exit 1
fi
_COMMON_SH_LOADED=1

SCAN_HOOK_ID="${SCAN_HOOK_ID:-unknown}"

source "$(dirname -- "${BASH_SOURCE[0]}")/tool-paths.sh"

# Pre-push wrappers re-enter only after the transaction runner has copied the
# exact object tree. Legacy local-state selection requires an explicit opt-in.
run_push_snapshot() {
    [[ "${SCAN_PUSH_SNAPSHOT:-0}" == 1 || "${SCAN_LEGACY_PUSH_STATE:-0}" == 1 ]] && return 0
    local py
    py="$(find_python)" || { hook_error 'Python is required for push snapshots'; exit 1; }
    # Ignore Python environment paths and the checkout, retaining trusted user packages.
    "$py" -E -P "${SCRIPT_DIR}/pre-push.py" --shell sh --hooks "$(basename "${BASH_SOURCE[1]}" .sh)" "$@"
    exit $?
}

# Re-enter passive commit scanners after one batch export of index blobs.
run_staged_snapshot() {
    [[ "${SCAN_INDEX_SNAPSHOT:-0}" == 1 ]] && return 0
    local py
    py="$(find_python)" || { hook_error 'Python is required for index snapshots'; exit 1; }
    "$py" -E -P "${SCRIPT_DIR}/pre-commit.py" --shell sh "$(basename "${BASH_SOURCE[1]}" .sh)" "$@"
    exit $?
}

prepare_checkov_policy() {
    local py source
    # Direct legacy Git hooks receive the remote name and URL, never tool flags.
    if [[ "${SCAN_LEGACY_PUSH_STATE:-0}" == 1 && "${SCAN_PUSH_SNAPSHOT:-0}" != 1 && $# -eq 2 &&
          -n "$1" && "$1" != -* && -n "$2" && "$2" != -* ]]; then
        set --
    fi
    [[ $# -eq 0 ]] || { hook_error 'Checkov extra arguments are disabled'; exit 1; }
    py="$(find_python)" || { hook_error 'Python is required for passive Checkov policy'; exit 1; }
    source="$(resolve_config '.checkov.yaml' 2>/dev/null || true)"
    checkov_policy_dir="$(mktemp -d)" || exit 1
    trap 'rm -rf -- "$checkov_policy_dir"' EXIT
    "$py" -E -P "${SCRIPT_DIR}/lib/checkov_policy.py" "$source" > "$checkov_policy_dir/policy.yaml" || exit 1
    checkov_policy_file="$checkov_policy_dir/policy.yaml"
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

hook_log() {
    echo "[${SCAN_HOOK_ID}] $*"
}

hook_warn() {
    echo "[${SCAN_HOOK_ID}] WARNING: $*" >&2
}

hook_error() {
    echo "[${SCAN_HOOK_ID}] ERROR: $*" >&2
}

hook_verbose() {
    if [[ "${SCAN_VERBOSE:-0}" == "1" ]]; then
        echo "[${SCAN_HOOK_ID}] DEBUG: $*" >&2
    fi
}

# ---------------------------------------------------------------------------
# Exit code handling (block incomplete scans unless explicitly opted out)
# ---------------------------------------------------------------------------

# Classify a tool exit code:
#   exit 0 = no findings (pass)
#   exit 1 = security findings found (block)
#   exit 2+ = infrastructure error (block; explicit local opt-in warns + allows)
#
# Usage: handle_exit_code $tool_exit_code
# Returns: 0 (pass/fail-open) or 1 (findings found)
handle_exit_code() {
    local exit_code="${1:?Exit code required}"

    case "${exit_code}" in
        0)
            return 0
            ;;
        1)
            return 1
            ;;
        *)
            if [[ "${SCAN_ALLOW_TOOL_ERRORS:-0}" == 1 ]]; then
                hook_warn "Tool error (exit code ${exit_code}); explicit local fail-open opt-in"
                return 0
            fi
            hook_error "Tool error (exit code ${exit_code}); scan incomplete"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# JSON output
# ---------------------------------------------------------------------------

# Ensure the .scanning directory exists
# Check every component without resolving away symlinks or Windows junctions.
assert_safe_write_path() {
    local py
    if ! py="$(find_python)"; then
        # POSIX has symlinks only. Windows junction checks require an interpreter.
        case "${OSTYPE:-}" in msys*|cygwin*) hook_error 'Python required for Windows path checks'; exit 1 ;; esac
        local component="$1"
        [[ "$component" == /* ]] || component="$PWD/$component"
        while [[ -n "$component" ]]; do
            [[ ! -L "$component" ]] || { hook_error 'Refusing a symlink in output path'; exit 1; }
            component="${component%/*}"
        done
        return 0
    fi
    "$py" -I - "$1" <<'PYSAFE' || exit 1
import os, pathlib, stat, sys
p = pathlib.Path(os.path.abspath(sys.argv[1]))
for part in (*reversed(p.parents), p):
    try: info = part.lstat()
    except FileNotFoundError: continue
    if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400:
        sys.exit("Refusing a symlink or reparse point in output path")
PYSAFE
}

ensure_scanning_dir() {
    assert_safe_write_path .scanning/last-scan.json
    mkdir -p .scanning
}

write_scan_json() (
    local json_content="${1:?JSON content required}" temporary attempt started
    ensure_scanning_dir
    temporary="$(mktemp .scanning/.scan-write-XXXXXX)" || exit 1
    # A subshell keeps cleanup local and preserves the caller's traps.
    trap 'rm -f -- "$temporary"' EXIT
    printf '%s\n' "$json_content" > "$temporary" || exit 1
    started=-1
    for ((attempt=0; attempt<20; attempt++)); do
        assert_safe_write_path .scanning/last-scan.json
        # mv otherwise treats a directory as an output folder and reports success.
        [[ ! -d .scanning/last-scan.json ]] || { hook_error 'Report destination is a directory'; exit 1; }
        if mv -f -- "$temporary" .scanning/last-scan.json; then
            exit 0
        fi
        # Windows can deny rename while another hook is publishing the report.
        # Some mv implementations also retry internally; cap elapsed time as well.
        if (( started < 0 )); then started=$SECONDS; fi
        if (( attempt == 19 || SECONDS - started >= 2 )); then break; fi
        sleep 0.05
    done
    hook_error 'Could not publish scan report after bounded retries'
    exit 1
)

assert_external_path() {
    local py
    local external_path="$1"
    if ! py="$(find_python)"; then
        case "${OSTYPE:-}" in msys*|cygwin*) hook_error 'Python required for Windows path checks'; exit 1 ;; esac
        [[ "$external_path" == /* && ! -L "$external_path" ]] || { hook_error 'Trusted path must be absolute and unlinked'; exit 1; }
        local root parent canonical consumer_root
        if [[ "${SCAN_PUSH_SNAPSHOT:-0}" == 1 || "${SCAN_INDEX_SNAPSHOT:-0}" == 1 ]]; then
            root="$PWD"
        else
            require_scan_git
            root="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
        fi
        root="$(cd "$root" && pwd -P)"
        parent="$(cd "$(dirname -- "$external_path")" && pwd -P)" || exit 1
        canonical="$parent/${external_path##*/}"
        case "$canonical/" in "$root/"*) hook_error 'Trusted path must be outside the scanned checkout'; exit 1 ;; esac
        if [[ -n "${SCAN_CONSUMER_ROOT:-}" && ( "${SCAN_PUSH_SNAPSHOT:-0}" == 1 || "${SCAN_INDEX_SNAPSHOT:-0}" == 1 ) ]]; then
            consumer_root="$(cd "$SCAN_CONSUMER_ROOT" && pwd -P)" || exit 1
            case "$canonical/" in "$consumer_root/"*) hook_error 'Trusted path must be outside the consumer checkout'; exit 1 ;; esac
        fi
        return 0
    fi
    if command -v cygpath >/dev/null 2>&1; then external_path="$(cygpath -w "$external_path")"; fi
    [[ "${SCAN_PUSH_SNAPSHOT:-0}" == 1 || "${SCAN_INDEX_SNAPSHOT:-0}" == 1 ]] || require_scan_git
    "$py" -I - "$external_path" <<'PYEXTERNAL'  || exit 1
import os, pathlib, subprocess, sys
try:
    if any(os.environ.get(key) == '1' for key in ('SCAN_PUSH_SNAPSHOT', 'SCAN_INDEX_SNAPSHOT')):
        root = pathlib.Path.cwd().resolve()
    else:
        # Keep Git's exact bytes: stripping whitespace or translating newlines
        # in text mode could name a different directory and move the boundary.
        output = subprocess.check_output(['git', 'rev-parse', '--show-toplevel']).removesuffix(b'\n')
        if os.name == 'nt':
            output = output.removesuffix(b'\r')
        output.decode('utf-8')
        # Match argv's filesystem representation after strict UTF-8 validation.
        root = pathlib.Path(os.fsdecode(output)).resolve()
except UnicodeDecodeError:
    # Replacing bytes could move the boundary and allow a checkout-owned path.
    sys.exit("Cannot decode Git checkout root as UTF-8; refusing trusted path")
except subprocess.CalledProcessError:
    root = pathlib.Path.cwd().resolve()
p = pathlib.Path(sys.argv[1])
roots = [root]
if any(os.environ.get(key) == '1' for key in ('SCAN_PUSH_SNAPSHOT', 'SCAN_INDEX_SNAPSHOT')) and os.environ.get('SCAN_CONSUMER_ROOT'):
    roots.append(pathlib.Path(os.environ['SCAN_CONSUMER_ROOT']).resolve())
if not p.is_absolute():
    sys.exit("Trusted path must be absolute and outside the scanned checkout")
for boundary in roots:
    try:
        p.resolve().relative_to(boundary)
    except ValueError:
        continue
    sys.exit("Trusted path must be outside the scanned and consumer checkouts")
PYEXTERNAL
}

# Trusted tools/configuration live outside the scanned checkout. The explicit
# opt-in is for developer-owned projects whose executable configuration is trusted.
require_trusted_app_tool() {
    local tool="$1" bin_var="SCAN_${1^^}_BIN" config_var="SCAN_${1^^}_CONFIG" py
    runner=("${!bin_var:-}")
    trusted_config="${!config_var:-}"
    [[ -n "${runner[0]}" && -n "$trusted_config" ]] || { hook_error "Set $bin_var and $config_var to external trusted paths"; exit 1; }
    [[ -f "${runner[0]}" && -f "$trusted_config" ]] || { hook_error 'Trusted tool/config missing'; exit 1; }
    assert_external_path "${runner[0]}"
    assert_external_path "$trusted_config"
}

# Build a minimal last-scan.json for a passing scan
# Usage: build_pass_json "$tool" "$scan_dir" "$duration_ms"
build_pass_json() {
    local tool="${1:?Tool name required}"
    local scan_dir="${2:-.}"
    local duration_ms="${3:-0}"
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')"

    # Escape backslashes and quotes for valid JSON strings
    scan_dir="${scan_dir//\\/\\\\}"
    scan_dir="${scan_dir//\"/\\\"}"

    cat <<ENDJSON
{
  "schema_version": "1.0",
  "scan_id": "$(generate_id)",
  "scan_timestamp": "${timestamp}",
  "duration_ms": ${duration_ms},
  "scan_directory": "${scan_dir}",
  "tools_executed": ["${tool}"],
  "auto_fix_applied": false,
  "auto_fix_count": 0,
  "summary": {
    "total_findings": 0,
    "by_severity": {"CRITICAL": 0, "HIGH": 0, "MEDIUM": 0, "LOW": 0},
    "by_tool": {"${tool}": 0},
    "fixable": 0,
    "unfixable": 0
  },
  "findings": []
}
ENDJSON
}

# Build a last-scan.json for a scan with findings
# Usage: build_findings_json "$tool" "$scan_dir" "$duration_ms" "$findings_json_array" "$critical" "$high" "$medium" "$low"
build_findings_json() {
    local tool="${1:?Tool name required}"
    local scan_dir="${2:-.}"
    local duration_ms="${3:-0}"
    local findings="${4:-[]}"
    local critical="${5:-0}"
    local high="${6:-0}"
    local medium="${7:-0}"
    local low="${8:-0}"
    local total=$((critical + high + medium + low))
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')"

    # Escape backslashes and quotes for valid JSON strings
    scan_dir="${scan_dir//\\/\\\\}"
    scan_dir="${scan_dir//\"/\\\"}"

    cat <<ENDJSON
{
  "schema_version": "1.0",
  "scan_id": "$(generate_id)",
  "scan_timestamp": "${timestamp}",
  "duration_ms": ${duration_ms},
  "scan_directory": "${scan_dir}",
  "tools_executed": ["${tool}"],
  "auto_fix_applied": false,
  "auto_fix_count": 0,
  "summary": {
    "total_findings": ${total},
    "by_severity": {"CRITICAL": ${critical}, "HIGH": ${high}, "MEDIUM": ${medium}, "LOW": ${low}},
    "by_tool": {"${tool}": ${total}},
    "fixable": 0,
    "unfixable": ${total}
  },
  "findings": ${findings}
}
ENDJSON
}

# ---------------------------------------------------------------------------
# Monorepo / directory detection
# ---------------------------------------------------------------------------

# Print changed files for dir-detection, NUL-delimited (-z). Prefer the staged index
# (pre-commit); when it is empty (the usual case at pre-push) fall back to the push
# range so pushed commits are still scanned. NUL output keeps paths with whitespace
# or newlines intact. Best-effort — CI is the authoritative backstop.
# Capture producer status before reading NUL paths; process substitution alone
# loses that status and can mistake a failed enumeration for an empty change set.
read_nul_paths() {
    local destination="$1" listing
    shift
    listing="$(mktemp)" || exit 1
    if ! "$@" > "$listing"; then
        rm -f -- "$listing"
        hook_error "Could not enumerate scan inputs"
        exit 1
    fi
    mapfile -d '' -t "$destination" < "$listing"
    rm -f -- "$listing"
}

require_scan_git() {
    command -v git >/dev/null 2>&1 || { hook_error 'git is required to read scan inputs; scan incomplete'; exit 1; }
}

_changed_files_for_detect() {
    if [[ -n "${SCAN_PUSH_FILES:-}" ]]; then
        cat -- "$SCAN_PUSH_FILES"
        return
    fi
    require_scan_git
    local listing reference
    listing="$(mktemp)" || return 1
    git diff --cached --name-only -z --diff-filter=ACMR -- > "$listing" || { rm -f -- "$listing"; return 1; }
    if [[ ! -s "$listing" ]]; then
        for reference in '@{push}' '@{upstream}'; do
            if git rev-parse --verify -q "$reference" >/dev/null 2>&1; then
                git diff --name-only -z --diff-filter=ACMR "$reference" HEAD -- > "$listing" || { rm -f -- "$listing"; return 1; }
                [[ -s "$listing" ]] && break
            fi
        done
    fi
    cat -- "$listing"
    rm -f -- "$listing"
}

# Detect directories containing Terraform files that have changed
# Uses git diff to find changed .tf files and extracts unique directories
# Returns EMPTY when no .tf files are staged — hooks should skip scanning
# Usage: mapfile -t scan_dirs < <(detect_changed_dirs)
# Output: Newline-separated list of directories, or empty if none
detect_changed_dirs() {
    if [[ -z "${SCAN_PUSH_FILES:-}" ]]; then
        require_scan_git
        if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            if [[ "${SCAN_PUSH_SNAPSHOT:-0}" == 1 ]]; then
                hook_error 'Could not enumerate push scan inputs; scan incomplete'
                return 1
            fi
            # A local caller outside a repository has no selected inputs.
            return 0
        fi
    fi

    _changed_files_for_detect | while IFS= read -r -d '' path; do
        [[ "${path,,}" == *.tf || "${path,,}" == *.tf.json ]] || continue
        if [[ "$path" == */* ]]; then printf '%s\0' "${path%/*}"; else printf '.\0'; fi
    done | LC_ALL=C sort -zu
}

# Directories remain NUL-delimited through every caller.
detect_all_changed_dirs() {
    _changed_files_for_detect | while IFS= read -r -d '' path; do
        if [[ "$path" == */* ]]; then printf '%s\0' "${path%/*}"; else printf '.\0'; fi
    done | LC_ALL=C sort -zu
}

# Count .tf files in given directories
# Usage: count_tf_files dir1 dir2 ...
count_tf_files() {
    local count=0
    for dir in "$@"; do
        if [[ -d "${dir}" ]]; then
            local dir_count
            local search_dir="${dir}"
            [[ "$search_dir" == /* ]] || search_dir="./$search_dir"
            dir_count="$(find -- "${search_dir}" -maxdepth 3 \( -iname '*.tf' -o -iname '*.tf.json' \) -not -path '*/.terraform/*' -print0 2>/dev/null | tr -cd '\0' | wc -c)"
            count=$((count + dir_count))
        fi
    done
    echo "${count}"
}

# ---------------------------------------------------------------------------
# App-code helpers (shared by csharp/typescript/sql hooks — STEP 2)
# ---------------------------------------------------------------------------

# Print staged files (added/copied/modified/renamed) optionally filtered by
# extension. Extensions are matched case-insensitively, without the dot.
# Usage: mapfile -t files < <(get_staged_files cs csproj)
#        mapfile -t files < <(get_staged_files)   # all staged files
get_staged_files() {
    local path ext listing
    listing="$(mktemp)" || return 1
    if [[ -n "${SCAN_PUSH_FILES:-}" ]]; then
        cat -- "$SCAN_PUSH_FILES" > "$listing" || { rm -f -- "$listing"; return 1; }
    else
        require_scan_git
        git diff --cached --name-only -z --diff-filter=ACMR -- > "$listing" || { rm -f -- "$listing"; return 1; }
    fi
    while IFS= read -r -d '' path; do
        if [[ $# -eq 0 ]]; then printf '%s\0' "$path"; continue; fi
        for ext in "$@"; do
            if [[ "${path,,}" == *."${ext,,}" ]]; then printf '%s\0' "$path"; break; fi
        done
    done < "$listing"
    rm -f -- "$listing"
}

# Export the given staged files (from the git index, not the working tree) into a
# fresh temp dir, preserving relative paths. Prints the temp dir path; caller must
# rm -rf it (and should set a trap).
# Usage: tmpdir="$(export_staged_to_tmp "${files[@]}")"; trap 'rm -rf "$tmpdir"' EXIT
export_staged_to_tmp() {
    require_scan_git
    local tmpdir
    tmpdir="$(mktemp -d)" || return 1
    local file file_dir
    for file in "$@"; do
        [[ -z "${file}" ]] && continue
        file_dir="."; [[ "$file" == */* ]] && file_dir="${file%/*}"
        [[ "${file_dir}" != "." ]] && mkdir -p "${tmpdir}/${file_dir}"
        git show ":${file}" -- > "${tmpdir}/${file}" 2>/dev/null || {
            rm -rf -- "$tmpdir"
            hook_error "Could not export staged '$file'; scan incomplete"
            return 1
        }
    done
    echo "${tmpdir}"
}

# Require Python 3.11+ with the same safe-path flags used by config reads.
# Skip broken launcher shims and older interpreters. Prints the command name.
find_python() {
    local c candidate
    for c in python python3 py; do
        type -P -- "$c" >/dev/null 2>&1 || continue
        candidate="$(resolve_verified_tool "$c")" || return 1
        local windows_py=0
        # A case pattern, not an extended glob: older shells fail to parse @(...) in [[ ]].
        case "${OSTYPE:-}" in msys*|cygwin*|mingw*|win*) [[ "$c" == py ]] && windows_py=1 ;; esac
        if (( windows_py )); then
            local interpreter listing line defaults=()
            if [[ -n "${VIRTUAL_ENV:-}" ]]; then
                interpreter="$VIRTUAL_ENV/Scripts/python.exe"
            else
                listing="$("$candidate" -0p 2>/dev/null)" || {
                    hook_error 'Cannot verify py selection; put python or python3 on PATH'; return 1;
                }
                while IFS= read -r line; do
                    line="${line%$'\r'}"
                    if [[ "$line" =~ ^[[:space:]]*-[^[:space:]]+[[:space:]]+\*[[:space:]]+(.+)$ ]]; then
                        defaults+=("${BASH_REMATCH[1]}")
                    fi
                done <<< "$listing"
                [[ ${#defaults[@]} -eq 1 ]] || {
                    hook_error 'Cannot verify py selection; put python or python3 on PATH'; return 1;
                }
                interpreter="${defaults[0]}"
                interpreter="${interpreter#\"}"; interpreter="${interpreter%\"}"
            fi
            if [[ "${OSTYPE:-}" == cygwin* ]]; then
                interpreter="$(cygpath -u -- "$interpreter")" || {
                    hook_error 'Cannot convert py interpreter path'; return 1;
                }
            fi
            [[ -f "$interpreter" ]] || { hook_error 'Cannot verify py virtual environment or default'; return 1; }
            candidate="$(verify_tool_path "$interpreter")" || return 1
        fi
        if "$candidate" -E -P -c "" >/dev/null 2>&1; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# Read a dotted string key. Missing config/keys retain defaults; malformed
# configuration blocks with a named error instead of silently using defaults.
# Usage: solution="$(read_scan_config languages.csharp.build.solution '')"
read_scan_config() {
    local key="${1:?key required}"
    local default="${2:-}"
    local cfg="${SCAN_CONFIG_FILE:-scan-config.yaml}"
    [[ -f "${cfg}" ]] || { echo "${default}"; return 0; }
    local py
    py="$(find_python)" || { hook_error 'Python is required to read scan-config.yaml'; return 1; }
    "${py}" -E -P "$(dirname -- "${BASH_SOURCE[0]}")/scan_config.py" "${key}" "${cfg}" "${default}"
}

# Python helper source (single-quoted -c arg avoids fragile heredocs-in-$()).
# Semgrep is a Python package, so python is available wherever semgrep runs.
_SEMGREP_COUNT_PY='
import sys, json
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
    if not isinstance(d, dict) or not isinstance(d.get("results"), list) or d.get("errors"):
        raise ValueError("Incomplete scanner report")
    h = m = l = 0
    for r in d["results"]:
        sev = str(r.get("extra", {}).get("severity") or "").upper()
        if sev == "ERROR": h += 1
        elif sev == "WARNING": m += 1
        else: l += 1
    print(h, m, l, h + m + l)
except Exception:
    sys.exit(3)
'
_SEMGREP_PRINT_PY='
import sys, json
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
    for r in d.get("results", [])[:25]:
        sev = str(r.get("extra", {}).get("severity") or "").upper()
        msg = (str(r.get("extra", {}).get("message") or "").splitlines() or [""])[0]
        print("  %s  %s  %s:%s" % (sev, r.get("check_id",""), r.get("path",""), r.get("start",{}).get("line",0)))
        print("    %s" % msg)
except Exception:
    pass
'

# Count Semgrep findings by severity from a --json output file.
# Prints "<high> <medium> <low> <total>" (ERROR->HIGH, WARNING->MEDIUM, INFO->LOW).
count_semgrep_severities() {
    local json="${1:?json file required}"
    [[ -f "${json}" ]] || return 2
    local py result
    py="$(find_python 2>/dev/null)" || py=""
    if [[ -n "${py}" ]]; then
        result="$("${py}" -I -c "${_SEMGREP_COUNT_PY}" "${json}" 2>/dev/null)"
        if [[ $? -eq 0 && -n "${result}" ]]; then
            echo "${result}"
            return 0
        fi
    fi
    return 2
}

# Print a concise list of Semgrep findings from a --json output file.
print_semgrep_findings() {
    local json="${1:-}"
    [[ -f "${json}" ]] || return 0
    local py out
    py="$(find_python 2>/dev/null)" || return 0
    out="$("${py}" -I -c "${_SEMGREP_PRINT_PY}" "${json}" 2>/dev/null)" || return 0
    [[ -n "${out}" ]] && printf '%s\n' "${out}"
}

# Auto-detect the nearest .slnx/.sln under a working dir when build.solution is empty.
# Prints the solution path relative to the working dir, or empty if none found.
# Usage: sln="$(detect_dotnet_solution "${working_dir}")"
detect_dotnet_solution() {
    local wd="${1:-.}"
    [[ -d "${wd}" ]] || { echo ""; return 0; }
    local found
    found="$(find "${wd}" -maxdepth 3 \( -name '*.slnx' -o -name '*.sln' \) 2>/dev/null | head -n1)"
    echo "${found}"
}

# ---------------------------------------------------------------------------
# Config resolution
# ---------------------------------------------------------------------------

# Resolve a config file path, checking .scanning/configs/ first
# Usage: resolve_config "filename" [--fallback "default_path"]
resolve_config() {
    local filename="${1:?Filename required}"
    local fallback="${3:-}"

    # Priority 1: Consuming repo's downloaded configs
    if [[ -f "${SCAN_CONFIG_DIR:-.scanning/configs}/${filename}" ]]; then
        echo "${SCAN_CONFIG_DIR:-.scanning/configs}/${filename}"
        return 0
    fi

    # Priority 2: Fallback path if provided
    if [[ -n "${fallback}" && -f "${fallback}" ]]; then
        echo "${fallback}"
        return 0
    fi

    # No config found
    return 1
}

# ---------------------------------------------------------------------------
# Trivy-specific helpers
# ---------------------------------------------------------------------------

# Run a Trivy command with DB lock retry logic
# Usage: run_trivy_with_retry arg1 arg2 arg3 ...
# Pass arguments as separate words (NOT as a single string with eval).
# Returns: Trivy exit code (0, 1, or 2 for fail-open on persistent lock)
run_trivy_with_retry() {
    local output exit_code diagnostics attempt
    diagnostics="$(mktemp)" || return 2
    for attempt in 1 2; do
        output="$("$@" 2>"$diagnostics")" && exit_code=0 || exit_code=$?
        if [[ "$exit_code" -ne 0 ]] && grep -qiE 'database.*locked|cache may be in use by another process' -- "$diagnostics"; then
            [[ "$attempt" == 1 ]] && { hook_warn "Trivy database locked; retrying"; sleep 2; continue; }
            exit_code=2
        fi
        cat -- "$diagnostics" >&2
        rm -f -- "$diagnostics"
        printf '%s\n' "$output"
        return "$exit_code"
    done
}

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

# Generate a simple unique ID (not a full UUID but sufficient for scan IDs)
generate_id() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' && return 0
    fi
    # Fallback: timestamp + random
    echo "scan-$(date +%s)-${RANDOM}"
}

# Check if a tool is available on PATH
# Usage: require_tool "trivy" || return 2
require_tool() {
    local tool="${1:?Tool name required}"
    if ! type -P -- "${tool}" >/dev/null 2>&1; then
        if [[ "${SCAN_ALLOW_TOOL_ERRORS:-0}" != 1 ]]; then
            hook_error "${tool} not found; scan incomplete"
            exit 1
        fi
        hook_warn "${tool} unavailable; explicit local fail-open opt-in"
        return 2
    fi
    SCAN_TOOL="$(resolve_verified_tool "$tool")" || exit 1
    return 0
}

# Measure command execution time in milliseconds
# Usage: start_timer / stop_timer
# Sets SCAN_START_TIME and returns duration in ms
start_timer() {
    SCAN_TIMER_NS=0
    if command -v date >/dev/null 2>&1; then
        local ts
        ts="$(date +%s%N 2>/dev/null || date +%s)"
        # Check if the output is all digits (nanosecond support present)
        if [[ "${ts}" =~ ^[0-9]+$ ]] && [[ ${#ts} -gt 12 ]]; then
            SCAN_TIMER_NS=1
            SCAN_START_TIME="${ts}"
        else
            # macOS or other systems without %N support — fall back to seconds
            SCAN_TIMER_NS=0
            SCAN_START_TIME="$(date +%s)"
        fi
    else
        SCAN_START_TIME="$(date +%s)"
    fi
}

stop_timer() {
    local end_time
    if [[ "${SCAN_TIMER_NS:-0}" -eq 1 ]]; then
        end_time="$(date +%s%N 2>/dev/null)"
        if [[ "${end_time}" =~ ^[0-9]+$ ]]; then
            echo $(( (end_time - SCAN_START_TIME) / 1000000 ))
        else
            # Fallback if %N stopped working mid-run
            end_time="$(date +%s)"
            echo $(( (end_time - ${SCAN_START_TIME:0:10}) * 1000 ))
        fi
    else
        end_time="$(date +%s)"
        echo $(( (end_time - SCAN_START_TIME) * 1000 ))
    fi
}

# Format findings summary for human output
# Usage: format_summary $critical $high $medium $low
format_summary() {
    local critical="${1:-0}" high="${2:-0}" medium="${3:-0}" low="${4:-0}"
    local total=$((critical + high + medium + low))
    echo "${total} findings (${critical} critical, ${high} high, ${medium} medium, ${low} low)"
}

# Parse severity counts from Trivy JSON output
# Usage: parse_trivy_severities "$json_output"
# Sets: TRIVY_CRITICAL, TRIVY_HIGH, TRIVY_MEDIUM, TRIVY_LOW
parse_trivy_severities() {
    local json="${1:-}"
    if [[ -z "${json}" ]] || ! command -v jq >/dev/null 2>&1; then
        TRIVY_CRITICAL=0; TRIVY_HIGH=0; TRIVY_MEDIUM=0; TRIVY_LOW=0
        return 0
    fi

    TRIVY_CRITICAL="$(echo "${json}" | jq '[.Results[]?.Misconfigurations[]? | select(.Severity == "CRITICAL")] | length' 2>/dev/null || echo 0)"
    TRIVY_HIGH="$(echo "${json}" | jq '[.Results[]?.Misconfigurations[]? | select(.Severity == "HIGH")] | length' 2>/dev/null || echo 0)"
    TRIVY_MEDIUM="$(echo "${json}" | jq '[.Results[]?.Misconfigurations[]? | select(.Severity == "MEDIUM")] | length' 2>/dev/null || echo 0)"
    TRIVY_LOW="$(echo "${json}" | jq '[.Results[]?.Misconfigurations[]? | select(.Severity == "LOW")] | length' 2>/dev/null || echo 0)"
}

# Print actionable details for Trivy IaC findings
# Usage: print_trivy_iac_findings "$json_output"
# Shows: severity, rule ID, file:line, title, and resolution for each finding
print_trivy_iac_findings() {
    local json="${1:-}"
    if [[ -z "${json}" ]] || ! command -v jq >/dev/null 2>&1; then
        hook_log "  (install jq to see finding details)"
        return 0
    fi

    local findings
    findings="$(echo "${json}" | jq -r '
        [.Results[]? | .Target as $target |
         .Misconfigurations[]? |
         {severity: .Severity, id: .ID, title: .Title, resolution: .Resolution,
          target: $target, start: .CauseMetadata.StartLine, end: .CauseMetadata.EndLine,
          resource: .CauseMetadata.Resource}] |
        sort_by(if .severity == "CRITICAL" then 0 elif .severity == "HIGH" then 1
                elif .severity == "MEDIUM" then 2 else 3 end) |
        .[] |
        "  \(.severity)  \(.id)  \(.target):\(.start)-\(.end)\n    \(.title)\n    Resource: \(.resource)\n    Fix: \(.resolution)"
    ' 2>/dev/null)" || true

    if [[ -n "${findings}" ]]; then
        hook_log ""
        while IFS= read -r line; do
            hook_log "${line}"
        done <<< "${findings}"
        hook_log ""
    fi
}

# Print actionable details for Trivy secret findings
# Usage: print_trivy_secret_findings "$json_output"
print_trivy_secret_findings() {
    local json="${1:-}"
    if [[ -z "${json}" ]] || ! command -v jq >/dev/null 2>&1; then
        hook_log "  (install jq to see finding details)"
        return 0
    fi

    local findings
    findings="$(echo "${json}" | jq -r '
        [.Results[]? | .Target as $target |
         .Secrets[]? |
         {severity: .Severity, rule: .RuleID, title: .Title, target: $target,
          start: .StartLine, end: .EndLine}] |
        .[] |
        "  \(.severity)  \(.rule)  \(.target):\(.start)-\(.end)\n    \(.title)"
    ' 2>/dev/null)" || true

    if [[ -n "${findings}" ]]; then
        hook_log ""
        while IFS= read -r line; do
            hook_log "${line}"
        done <<< "${findings}"
        hook_log ""
    fi
}

# Print actionable details for Checkov findings
# Usage: print_checkov_findings "$json_output"
print_checkov_findings() {
    local json="${1:-}"
    if [[ -z "${json}" ]] || ! command -v jq >/dev/null 2>&1; then
        hook_log "  (install jq to see finding details)"
        return 0
    fi

    local findings
    findings="$(echo "${json}" | jq -r '
        [.results?.failed_checks[]? |
         {severity: (.severity // "UNKNOWN"), id: .check_id, name: .check_name,
          resource: .resource_address, file: .file_path,
          start: .file_line_range[0], end: .file_line_range[1],
          guideline: (.guideline // "")}] |
        sort_by(if .severity == "CRITICAL" then 0 elif .severity == "HIGH" then 1
                elif .severity == "MEDIUM" then 2 else 3 end) |
        .[] |
        "  \(.severity)  \(.id)  \(.file):\(.start)-\(.end)\n    \(.name)\n    Resource: \(.resource)\(if .guideline != "" then "\n    Guide: \(.guideline)" else "" end)"
    ' 2>/dev/null)" || true

    if [[ -n "${findings}" ]]; then
        hook_log ""
        while IFS= read -r line; do
            hook_log "${line}"
        done <<< "${findings}"
        hook_log ""
    fi
}

# Print actionable details for TFLint findings
# Usage: print_tflint_findings "$json_output"
print_tflint_findings() {
    local json="${1:-}"
    if [[ -z "${json}" ]] || ! command -v jq >/dev/null 2>&1; then
        hook_log "  (install jq to see finding details)"
        return 0
    fi

    local findings
    findings="$(echo "${json}" | jq -r '
        [.issues[]? |
         {severity: .rule.severity, name: .rule.name, message: .message,
          file: .range.filename, start: .range.start.line, end: .range.end.line}] |
        sort_by(if .severity == "error" then 0 elif .severity == "warning" then 1 else 2 end) |
        .[] |
        "  \(.severity | ascii_upcase)  \(.name)  \(.file):\(.start)-\(.end)\n    \(.message)"
    ' 2>/dev/null)" || true

    if [[ -n "${findings}" ]]; then
        hook_log ""
        while IFS= read -r line; do
            hook_log "${line}"
        done <<< "${findings}"
        hook_log ""
    fi
}

# Parse severity counts from Trivy secret scan JSON output
# Usage: parse_trivy_secret_severities "$json_output"
# Sets: TRIVY_CRITICAL, TRIVY_HIGH, TRIVY_MEDIUM, TRIVY_LOW
parse_trivy_secret_severities() {
    local json="${1:-}"
    if [[ -z "${json}" ]] || ! command -v jq >/dev/null 2>&1; then
        TRIVY_CRITICAL=0; TRIVY_HIGH=0; TRIVY_MEDIUM=0; TRIVY_LOW=0
        return 0
    fi

    TRIVY_CRITICAL="$(echo "${json}" | jq '[.Results[]?.Secrets[]? | select(.Severity == "CRITICAL")] | length' 2>/dev/null || echo 0)"
    TRIVY_HIGH="$(echo "${json}" | jq '[.Results[]?.Secrets[]? | select(.Severity == "HIGH")] | length' 2>/dev/null || echo 0)"
    TRIVY_MEDIUM="$(echo "${json}" | jq '[.Results[]?.Secrets[]? | select(.Severity == "MEDIUM")] | length' 2>/dev/null || echo 0)"
    TRIVY_LOW="$(echo "${json}" | jq '[.Results[]?.Secrets[]? | select(.Severity == "LOW")] | length' 2>/dev/null || echo 0)"
}
