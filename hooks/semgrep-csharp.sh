#!/usr/bin/env bash
# semgrep-csharp.sh — Semgrep SAST for C# (p/csharp ruleset)
# Stage: pre-commit | Mode: scan ONLY staged .cs files | native, no network
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_tool "semgrep" || exit 0

# Native path (Fall-2025) + UTF-8 so Semgrep runs without WSL on Windows.
export PYTHONUTF8=1
export SEMGREP_SEND_METRICS=off

mapfile -t files < <(get_staged_files cs)
if [[ ${#files[@]} -eq 0 ]]; then
    hook_log "PASS: No C# files staged"
    exit 0
fi

# Ruleset is overridable (tests/consumers); defaults to the registry pack.
ruleset="${SEMGREP_RULESET_CSHARP:-p/csharp}"

start_timer
hook_log "Scanning... (${#files[@]} C# files, ${ruleset})"

# Single --json run: gives accurate per-severity counts (no --error needed; semgrep
# exits non-zero only on its OWN errors, which we fail-open on).
tmpjson="$(mktemp)"
trap 'rm -f "${tmpjson}"' EXIT
semgrep_cmd=(semgrep scan --config "${ruleset}" --metrics off --json --output "${tmpjson}")
[[ $# -gt 0 ]] && semgrep_cmd+=("$@")
semgrep_cmd+=("${files[@]}")

set +e
"${semgrep_cmd[@]}" >/dev/null 2>&1
sg_exit=$?
set -e

duration_ms="$(stop_timer)"

if [[ ${sg_exit} -ne 0 && ! -s "${tmpjson}" ]]; then
    # Infrastructure error (semgrep itself failed) — fail-open
    handle_exit_code ${sg_exit}
    hook_log "PASS: scanner error, allowing commit (fail-open)"
    write_scan_json "$(build_pass_json "semgrep-csharp" "." "${duration_ms}")"
    exit 0
fi

read -r high medium low total < <(count_semgrep_severities "${tmpjson}")
if [[ "${total:-0}" -eq 0 ]]; then
    hook_log "PASS: No findings (${duration_ms}ms)"
    write_scan_json "$(build_pass_json "semgrep-csharp" "." "${duration_ms}")"
    exit 0
else
    print_semgrep_findings "${tmpjson}"
    hook_log "FAIL: $(format_summary 0 ${high} ${medium} ${low})"
    write_scan_json "$(build_findings_json "semgrep-csharp" "." "${duration_ms}" "[]" 0 "${high}" "${medium}" "${low}")"
    exit 1
fi
