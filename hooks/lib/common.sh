#!/usr/bin/env bash
# common.sh — Shared bash functions for hook scripts
# Sourced by all .sh hook wrappers via:
#   source "${SCRIPT_DIR}/lib/common.sh"

# Guard against double-sourcing
[[ -n "${_COMMON_SH_LOADED:-}" ]] && return 0
_COMMON_SH_LOADED=1

SCAN_HOOK_ID="${SCAN_HOOK_ID:-unknown}"

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
# Exit code handling (fail-open)
# ---------------------------------------------------------------------------

# Classify a tool exit code:
#   exit 0 = no findings (pass)
#   exit 1 = security findings found (block)
#   exit 2+ = infrastructure error (fail-open, warn + allow)
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
            hook_warn "Tool error (exit code ${exit_code}) - allowing commit (fail-open)"
            return 0
            ;;
    esac
}

# ---------------------------------------------------------------------------
# JSON output
# ---------------------------------------------------------------------------

# Ensure the .scanning directory exists
ensure_scanning_dir() {
    local scan_dir=".scanning"
    if [[ ! -d "${scan_dir}" ]]; then
        mkdir -p "${scan_dir}"
    fi
}

# Write scan results as JSON to .scanning/last-scan.json
# Usage: write_scan_json "$json_content"
write_scan_json() {
    local json_content="${1:?JSON content required}"
    ensure_scanning_dir
    echo "${json_content}" > ".scanning/last-scan.json"
    hook_verbose "Wrote scan results to .scanning/last-scan.json"
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
  "timestamp": "${timestamp}",
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
  "timestamp": "${timestamp}",
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
_changed_files_for_detect() {
    # Read NUL-delimited paths into an ARRAY — a scalar `files="$(... -z)"` would have
    # bash strip the NUL delimiters (command substitution drops NUL bytes), merging
    # paths and defeating the downstream `grep -z` / `xargs -0`. Then re-emit
    # NUL-delimited so callers keep whitespace/newline-safe paths.
    local -a files=()
    mapfile -d '' -t files < <(git diff --cached --name-only -z --diff-filter=ACMR 2>/dev/null)
    if (( ${#files[@]} == 0 )); then
        mapfile -d '' -t files < <(git diff --name-only -z --diff-filter=ACMR '@{push}' HEAD 2>/dev/null)
        (( ${#files[@]} == 0 )) && mapfile -d '' -t files < <(git diff --name-only -z --diff-filter=ACMR '@{upstream}' HEAD 2>/dev/null)
    fi
    local f
    for f in "${files[@]}"; do
        printf '%s\0' "${f}"
    done
}

# Detect directories containing Terraform files that have changed
# Uses git diff to find changed .tf files and extracts unique directories
# Returns EMPTY when no .tf files are staged — hooks should skip scanning
# Usage: mapfile -t scan_dirs < <(detect_changed_dirs)
# Output: Newline-separated list of directories, or empty if none
detect_changed_dirs() {
    if ! command -v git >/dev/null 2>&1 || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        # Not a git repo — return empty so hooks skip rather than scan everything
        return 0
    fi

    local dirs
    # Changed .tf dirs — staged at pre-commit, or the push range at pre-push.
    # NUL-safe: filter .tf paths, dirname them, dedupe — without breaking on
    # whitespace/newlines in paths (which would silently drop scan dirs).
    dirs="$(_changed_files_for_detect \
        | grep -z '\.tf$' \
        | xargs -0 -r -I{} dirname {} 2>/dev/null \
        | sort -u)"

    if [[ -n "${dirs}" ]]; then
        echo "${dirs}"
    fi
    # When no .tf files are staged, return empty — hooks will exit 0
}

# Detect directories containing ANY staged files (not just .tf)
# Used by secret detection hooks which scan all file types
# Returns EMPTY when no files are staged at all
# Usage: mapfile -t scan_dirs < <(detect_all_changed_dirs)
detect_all_changed_dirs() {
    if ! command -v git >/dev/null 2>&1 || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        return 0
    fi

    local dirs
    # NUL-safe: dirname each changed path, dedupe — without breaking on
    # whitespace/newlines in paths (which would silently drop scan dirs).
    dirs="$(_changed_files_for_detect \
        | xargs -0 -r -I{} dirname {} 2>/dev/null \
        | sort -u)"

    if [[ -n "${dirs}" ]]; then
        echo "${dirs}"
    fi
}

# Count .tf files in given directories
# Usage: count_tf_files dir1 dir2 ...
count_tf_files() {
    local count=0
    for dir in "$@"; do
        if [[ -d "${dir}" ]]; then
            local dir_count
            dir_count="$(find "${dir}" -maxdepth 3 -name '*.tf' -not -path '*/.terraform/*' 2>/dev/null | wc -l)"
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
    local files
    files="$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null)" || return 0
    [[ -z "${files}" ]] && return 0
    if [[ $# -eq 0 ]]; then
        echo "${files}"
        return 0
    fi
    local pattern=""
    local ext
    for ext in "$@"; do
        pattern+="${pattern:+|}\\.${ext}\$"
    done
    echo "${files}" | grep -iE "${pattern}" || true
}

# Export the given staged files (from the git index, not the working tree) into a
# fresh temp dir, preserving relative paths. Prints the temp dir path; caller must
# rm -rf it (and should set a trap).
# Usage: tmpdir="$(export_staged_to_tmp "${files[@]}")"; trap 'rm -rf "$tmpdir"' EXIT
export_staged_to_tmp() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local file file_dir
    for file in "$@"; do
        [[ -z "${file}" ]] && continue
        file_dir="$(dirname "${file}")"
        [[ "${file_dir}" != "." ]] && mkdir -p "${tmpdir}/${file_dir}"
        git show ":${file}" > "${tmpdir}/${file}" 2>/dev/null || true
    done
    echo "${tmpdir}"
}

# Find a Python interpreter that ACTUALLY runs (skips the broken Windows Store
# `python3` shim, which is on PATH but errors out). Prints the command name.
find_python() {
    local c
    for c in python python3 py; do
        if command -v "${c}" >/dev/null 2>&1 && "${c}" -c "" >/dev/null 2>&1; then
            echo "${c}"
            return 0
        fi
    done
    return 1
}

# Read a dotted key from scan-config.yaml (e.g. languages.csharp.build.solution).
# Falls back to the default if the config, python, PyYAML, or key is missing — so
# hooks degrade gracefully (e.g. empty solution => auto-detect) rather than break.
# Usage: solution="$(read_scan_config languages.csharp.build.solution '')"
read_scan_config() {
    local key="${1:?key required}"
    local default="${2:-}"
    local cfg="${SCAN_CONFIG_FILE:-scan-config.yaml}"
    [[ -f "${cfg}" ]] || { echo "${default}"; return 0; }
    local py
    py="$(find_python)" || { echo "${default}"; return 0; }
    "${py}" - "${key}" "${default}" "${cfg}" <<'PYEOF' 2>/dev/null || echo "${default}"
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
PYEOF
}

# Python helper source (single-quoted -c arg avoids fragile heredocs-in-$()).
# Semgrep is a Python package, so python is available wherever semgrep runs.
_SEMGREP_COUNT_PY='
import sys, json
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
    h = m = l = 0
    for r in d.get("results", []):
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
    [[ -f "${json}" ]] || { echo "0 0 0 0"; return 0; }
    local py result
    py="$(find_python 2>/dev/null)" || py=""
    if [[ -n "${py}" ]]; then
        result="$("${py}" -c "${_SEMGREP_COUNT_PY}" "${json}" 2>/dev/null)"
        if [[ $? -eq 0 && -n "${result}" ]]; then
            echo "${result}"
            return 0
        fi
    fi
    # Fallback only if python is genuinely unavailable: detect finding presence.
    if grep -q '"check_id"' "${json}" 2>/dev/null; then echo "1 0 0 1"; else echo "0 0 0 0"; fi
}

# Print a concise list of Semgrep findings from a --json output file.
print_semgrep_findings() {
    local json="${1:-}"
    [[ -f "${json}" ]] || return 0
    local py out
    py="$(find_python 2>/dev/null)" || return 0
    out="$("${py}" -c "${_SEMGREP_PRINT_PY}" "${json}" 2>/dev/null)" || return 0
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
    if [[ -f "${SCAN_CONFIG_DIR}/${filename}" ]]; then
        echo "${SCAN_CONFIG_DIR}/${filename}"
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
    local output
    local exit_code

    # First attempt — execute arguments directly without eval
    output="$("$@" 2>&1)" && exit_code=0 || exit_code=$?

    # Check for DB lock error
    if echo "${output}" | grep -qi "database.*locked" 2>/dev/null; then
        hook_warn "Trivy database locked, retrying in 2 seconds..."
        sleep 2

        # Retry once
        output="$("$@" 2>&1)" && exit_code=0 || exit_code=$?

        if echo "${output}" | grep -qi "database.*locked" 2>/dev/null; then
            hook_warn "Trivy database still locked after retry"
            echo "${output}"
            return 2
        fi
    fi

    echo "${output}"
    return "${exit_code}"
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
    if ! command -v "${tool}" >/dev/null 2>&1; then
        hook_warn "${tool} not found on PATH - allowing commit (fail-open)"
        return 2
    fi
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
