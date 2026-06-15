#!/usr/bin/env bash
# tflint.sh — TFLint Terraform linter
# Stage: pre-push | Severity: per config
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Verify tool availability
require_tool "tflint" || exit 0

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
total_high=0
total_medium=0
total_low=0

for dir in "${scan_dirs[@]}"; do
    if [[ ! -d "${dir}" ]]; then
        continue
    fi

    # Build tflint command as array — safe for paths with spaces/special chars
    tflint_cmd=(tflint --chdir="${dir}" --format json)

    # Check for config file
    config_file="$(resolve_config '.tflint.hcl' 2>/dev/null || true)"
    if [[ -n "${config_file}" ]]; then
        tflint_cmd+=(--config "${config_file}")
    fi

    # Add any extra args passed through
    if [[ $# -gt 0 ]]; then
        tflint_cmd+=("$@")
    fi

    # Initialize tflint plugins (required before scanning)
    set +e
    init_cmd=(tflint --chdir="${dir}" --init)
    if [[ -n "${config_file}" ]]; then
        init_cmd+=(--config "${config_file}")
    fi
    "${init_cmd[@]}" >/dev/null 2>&1
    set -e

    # Run tflint
    set +e
    output="$("${tflint_cmd[@]}" 2>&1)"
    exit_code=$?
    set -e

    if [[ ${exit_code} -eq 2 ]]; then
        # tflint uses exit 2 for findings (errors)
        if command -v jq >/dev/null 2>&1; then
            # tflint severity: error -> HIGH, warning -> MEDIUM, notice -> LOW
            local_error="$(echo "${output}" | jq '[.issues[]? | select(.rule.severity == "error")] | length' 2>/dev/null || echo 0)"
            local_warning="$(echo "${output}" | jq '[.issues[]? | select(.rule.severity == "warning")] | length' 2>/dev/null || echo 0)"
            local_notice="$(echo "${output}" | jq '[.issues[]? | select(.rule.severity == "notice")] | length' 2>/dev/null || echo 0)"
            total_high=$((total_high + local_error))
            total_medium=$((total_medium + local_warning))
            total_low=$((total_low + local_notice))
        else
            total_high=$((total_high + 1))
        fi
        # Show actionable details so developers know what to fix
        print_tflint_findings "${output}"
        overall_exit=1
    elif [[ ${exit_code} -eq 3 ]] || [[ ${exit_code} -ge 4 ]]; then
        # tflint exit 3+ = runtime error — fail-open.
        # '|| true' so handle_exit_code's return doesn't trip set -e (fail-open
        # must not terminate the script). Mirrors the PowerShell twin (tflint.ps1).
        handle_exit_code ${exit_code} || true
    elif [[ ${exit_code} -eq 1 ]]; then
        # tflint exit 1 = errors — treat as infrastructure error for consistency.
        # Some tflint versions use exit 1 for config errors. handle_exit_code returns
        # 1 for exit 1, which would terminate under set -e — '|| true' keeps it
        # fail-open as intended. Mirrors the PowerShell twin (tflint.ps1).
        handle_exit_code ${exit_code} || true
    fi
done

duration_ms="$(stop_timer)"

if [[ ${overall_exit} -eq 0 ]]; then
    hook_log "PASS: No findings above threshold"
    write_scan_json "$(build_pass_json "tflint" "." "${duration_ms}")"
else
    hook_log "FAIL: $(format_summary 0 ${total_high} ${total_medium} ${total_low})"
    write_scan_json "$(build_findings_json "tflint" "." "${duration_ms}" "[]" 0 "${total_high}" "${total_medium}" "${total_low}")"
fi

exit ${overall_exit}
