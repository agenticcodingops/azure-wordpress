#!/usr/bin/env bash
# checkov-strict.sh — Checkov Terraform strict scan (hard-fail on CRITICAL + HIGH)
# Stage: pre-push | Severity: CRITICAL + HIGH hard-fail
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

run_push_snapshot "$@"

# Verify tool availability
require_tool "checkov" || exit 0

start_timer

# Detect Terraform directories in the selected object tree.
read_nul_paths scan_dirs detect_changed_dirs

if [[ ${#scan_dirs[@]} -eq 0 ]]; then
    hook_log "PASS: No Terraform files selected"
    exit 0
fi

prepare_checkov_policy "$@"

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
    checkov_cmd=("$SCAN_TOOL" -d "${dir}" --framework terraform --output json --compact --quiet --hard-fail-on CRITICAL,HIGH)

    checkov_cmd+=(--config-file "$checkov_policy_file")

    # Run Checkov
    set +e
    output="$("${checkov_cmd[@]}" 2>&1)"
    exit_code=$?
    set -e

    if [[ ${exit_code} -eq 1 ]]; then
        # Parse findings from JSON output
        # printf '%s\n' (not echo) so values with backslashes or a leading '-'
        # are passed to jq verbatim rather than interpreted by echo.
        read -r local_critical local_high local_medium local_low < <(scanner_severity_counts "${output}" checkov)
        total_critical=$((total_critical + local_critical))
        total_high=$((total_high + local_high))
        total_medium=$((total_medium + local_medium))
        total_low=$((total_low + local_low))
        # Show actionable details so developers know what to fix
        print_checkov_findings "${output}"
        overall_exit=1
    elif [[ ${exit_code} -ge 2 ]]; then
        # Exit 2 or higher is a tool error: blocks unless SCAN_ALLOW_TOOL_ERRORS=1
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
