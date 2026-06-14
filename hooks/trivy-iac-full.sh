#!/usr/bin/env bash
# trivy-iac-full.sh — Trivy IaC full scan for all severities
# Stage: pre-push | Severity: All | --skip-check-update
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Verify tool availability
require_tool "trivy" || exit 0

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

    # Build Trivy command as array — safe for paths with spaces/special chars
    trivy_cmd=(trivy config "${dir}" --severity CRITICAL,HIGH,MEDIUM,LOW --exit-code 1 --format json --skip-check-update --quiet)

    # Check for config file
    config_file="$(resolve_config '.trivyignore' 2>/dev/null || true)"
    if [[ -n "${config_file}" ]]; then
        trivy_cmd+=(--ignorefile "${config_file}")
    fi

    # Add any extra args passed through
    if [[ $# -gt 0 ]]; then
        trivy_cmd+=("$@")
    fi

    # Run Trivy with retry logic
    set +e
    output="$(run_trivy_with_retry "${trivy_cmd[@]}")"
    exit_code=$?
    set -e

    if [[ ${exit_code} -eq 1 ]]; then
        # Parse findings from JSON output
        parse_trivy_severities "${output}"
        total_critical=$((total_critical + TRIVY_CRITICAL))
        total_high=$((total_high + TRIVY_HIGH))
        total_medium=$((total_medium + TRIVY_MEDIUM))
        total_low=$((total_low + TRIVY_LOW))
        # Show actionable details so developers know what to fix
        print_trivy_iac_findings "${output}"
        overall_exit=1
    elif [[ ${exit_code} -ge 2 ]]; then
        # Infrastructure error — fail-open
        handle_exit_code ${exit_code}
    fi
done

duration_ms="$(stop_timer)"

if [[ ${overall_exit} -eq 0 ]]; then
    hook_log "PASS: No findings above threshold"
    write_scan_json "$(build_pass_json "trivy" "." "${duration_ms}")"
else
    hook_log "FAIL: $(format_summary ${total_critical} ${total_high} ${total_medium} ${total_low})"
    write_scan_json "$(build_findings_json "trivy" "." "${duration_ms}" "[]" "${total_critical}" "${total_high}" "${total_medium}" "${total_low}")"
fi

exit ${overall_exit}
