#!/usr/bin/env bash
# gitleaks.sh — Gitleaks secret detection scanner
# Stage: pre-commit | Severity: HIGH (all secrets map to HIGH)
# Uses 'gitleaks protect --staged' to scan ONLY staged changes (not the whole repo)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Verify tool availability
require_tool "gitleaks" || exit 0

# Check if there are any staged files at all
staged_count="$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null | wc -l)"
if [[ "${staged_count}" -eq 0 ]]; then
    hook_log "PASS: No files staged"
    exit 0
fi

start_timer

hook_log "Scanning... (${staged_count} staged files)"

# Build Gitleaks command — 'protect --staged' only scans the staged git diff
gitleaks_cmd=(gitleaks protect --staged --report-format json --exit-code 1)

# Check for config file
config_file="$(resolve_config '.gitleaks.toml' 2>/dev/null || true)"
if [[ -n "${config_file}" ]]; then
    gitleaks_cmd+=(--config "${config_file}")
fi

# Add any extra args passed through
if [[ $# -gt 0 ]]; then
    gitleaks_cmd+=("$@")
fi

# Run Gitleaks on staged changes only
set +e
output="$("${gitleaks_cmd[@]}" 2>&1)"
exit_code=$?
set -e

total_high=0

if [[ ${exit_code} -eq 1 ]]; then
    # Parse findings — all Gitleaks findings map to HIGH severity
    if command -v jq >/dev/null 2>&1; then
        total_high="$(echo "${output}" | jq 'length' 2>/dev/null || echo 1)"
        # Show actionable details so developers know what to fix
        # Do NOT emit \(.Match) — it is the raw secret value. Rule + file:line is
        # enough to locate and fix it without leaking the secret into logs.
        gitleaks_details="$(echo "${output}" | jq -r '.[]? | "  HIGH  \(.RuleID)  \(.File):\(.StartLine)-\(.EndLine)\n    \(.Description)"' 2>/dev/null)" || true
        if [[ -n "${gitleaks_details}" ]]; then
            hook_log ""
            while IFS= read -r line; do
                hook_log "${line}"
            done <<< "${gitleaks_details}"
            hook_log ""
        fi
    else
        total_high=1
    fi
elif [[ ${exit_code} -ge 2 ]]; then
    # Infrastructure error — fail-open
    handle_exit_code ${exit_code}
    exit_code=0
fi

duration_ms="$(stop_timer)"

if [[ ${exit_code} -eq 0 ]]; then
    hook_log "PASS: No findings above threshold"
    write_scan_json "$(build_pass_json "gitleaks" "." "${duration_ms}")"
else
    hook_log "FAIL: $(format_summary 0 ${total_high} 0 0)"
    write_scan_json "$(build_findings_json "gitleaks" "." "${duration_ms}" "[]" 0 "${total_high}" 0 0)"
fi

exit ${exit_code}
