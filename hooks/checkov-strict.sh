#!/usr/bin/env bash
# checkov-strict.sh — Checkov Terraform strict scan (hard-fail on CRITICAL + HIGH)
# Stage: pre-push | Severity: CRITICAL + HIGH hard-fail
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Verify tool availability
require_tool "checkov" || exit 0

start_timer

# Detect scan directories (only dirs with staged .tf files)
mapfile -t scan_dirs < <(detect_changed_dirs)

if [[ ${#scan_dirs[@]} -eq 0 ]]; then
    hook_log "PASS: No Terraform files staged"
    exit 0
fi

file_count="$(count_tf_files "${scan_dirs[@]}")"
hook_log "Scanning... (${file_count} files in ${#scan_dirs[@]} directories)"

overall_exit=0
total_critical=0
total_high=0
total_medium=0
total_low=0

for dir in "${scan_dirs[@]}"; do
    if [[ ! -d "${dir}" ]]; then
        continue
    fi

    # Build Checkov command as array with hard-fail on CRITICAL,HIGH
    checkov_cmd=(checkov -d "${dir}" --framework terraform --output json --compact --quiet --hard-fail-on CRITICAL,HIGH)

    # Check for config file
    config_file="$(resolve_config '.checkov.yaml' 2>/dev/null || true)"
    if [[ -n "${config_file}" ]]; then
        checkov_cmd+=(--config-file "${config_file}")
    fi

    # Add any extra args passed through
    if [[ $# -gt 0 ]]; then
        checkov_cmd+=("$@")
    fi

    # Run Checkov
    set +e
    output="$("${checkov_cmd[@]}" 2>&1)"
    exit_code=$?
    set -e

    if [[ ${exit_code} -eq 1 ]]; then
        # Parse findings from JSON output
        if command -v jq >/dev/null 2>&1; then
            # printf '%s\n' (not echo) so values with backslashes or a leading '-'
            # are passed to jq verbatim rather than interpreted by echo.
            local_critical="$(printf '%s\n' "${output}" | jq '[.results?.failed_checks[]? | select(.severity == "CRITICAL")] | length' 2>/dev/null || echo 0)"
            local_high="$(printf '%s\n' "${output}" | jq '[.results?.failed_checks[]? | select(.severity == "HIGH")] | length' 2>/dev/null || echo 0)"
            local_medium="$(printf '%s\n' "${output}" | jq '[.results?.failed_checks[]? | select(.severity == "MEDIUM")] | length' 2>/dev/null || echo 0)"
            local_low="$(printf '%s\n' "${output}" | jq '[.results?.failed_checks[]? | select(.severity == "LOW" or .severity == null)] | length' 2>/dev/null || echo 0)"
            total_critical=$((total_critical + local_critical))
            total_high=$((total_high + local_high))
            total_medium=$((total_medium + local_medium))
            total_low=$((total_low + local_low))
        else
            total_critical=$((total_critical + 1))
        fi
        # Show actionable details so developers know what to fix
        print_checkov_findings "${output}"
        overall_exit=1
    elif [[ ${exit_code} -ge 2 ]]; then
        # Infrastructure error — fail-open
        handle_exit_code ${exit_code}
    fi
done

duration_ms="$(stop_timer)"

if [[ ${overall_exit} -eq 0 ]]; then
    hook_log "PASS: No findings above threshold"
    write_scan_json "$(build_pass_json "checkov" "." "${duration_ms}")"
else
    hook_log "FAIL: $(format_summary ${total_critical} ${total_high} ${total_medium} ${total_low})"
    write_scan_json "$(build_findings_json "checkov" "." "${duration_ms}" "[]" "${total_critical}" "${total_high}" "${total_medium}" "${total_low}")"
fi

exit ${overall_exit}
