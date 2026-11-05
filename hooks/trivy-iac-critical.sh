#!/usr/bin/env bash
# trivy-iac-critical.sh — Trivy IaC scan for CRITICAL misconfigurations only
# Stage: pre-commit | Severity: CRITICAL only | --skip-check-update
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

run_staged_snapshot "$@"

# Verify tool availability
require_tool "trivy" || exit 0

start_timer

# Detect scan directories (only dirs with staged .tf files)
read_nul_paths scan_dirs detect_changed_dirs

if [[ ${#scan_dirs[@]} -eq 0 ]]; then
    hook_log "PASS: No Terraform files staged"
    exit 0
fi

file_count="$(count_tf_files "${scan_dirs[@]}")"
hook_log "Scanning... (${file_count} files in ${#scan_dirs[@]} directories)"

overall_exit=0
total_critical=0

append_staged_tfvars() {
    local LC_ALL=C variable_file
    for variable_file in "$1/terraform.tfvars" "$1/"*.auto.tfvars; do
        [[ -f "$variable_file" ]] || continue
        trivy_cmd+=(--tf-vars "$variable_file")
    done
}

for dir in "${scan_dirs[@]}"; do
    if [[ ! -d "${dir}" ]]; then
        continue
    fi

    # Build Trivy command as array — safe for paths with spaces/special chars
    trivy_cmd=("$SCAN_TOOL" config --severity CRITICAL --exit-code 1 --format json --skip-check-update --quiet)
    if [[ "${SCAN_INDEX_SNAPSHOT:-0}" == 1 ]]; then
        append_staged_tfvars "$dir"
    fi

    # Check for config file
    config_file="$(resolve_config '.trivyignore' 2>/dev/null || true)"
    if [[ -n "${config_file}" ]]; then
        trivy_cmd+=(--ignorefile "${config_file}")
    fi

    # Add any extra args passed through
    if [[ $# -gt 0 ]]; then
        trivy_cmd+=("$@")
    fi

    trivy_cmd+=(-- "${dir}")

    # Run Trivy with retry logic
    set +e
    output="$(run_trivy_with_retry "${trivy_cmd[@]}")"
    exit_code=$?
    set -e

    if [[ "${SCAN_INDEX_SNAPSHOT:-0}" == 1 && ${exit_code} -eq 1 ]]; then
        py="$(find_python)" || { hook_error 'Python is required to select commit findings'; exit 1; }
        set +e
        output="$(printf '%s' "$output" | "$py" -I "${SCRIPT_DIR}/lib/trivy_selected.py" "$dir" "$SCAN_PUSH_FILES")"
        exit_code=$?
        set -e
        if [[ ${exit_code} -ne 0 && ${exit_code} -ne 1 ]]; then
            hook_error 'Invalid commit findings report; scan incomplete'
            exit 1
        fi
    fi

    if [[ ${exit_code} -eq 1 ]]; then
        # Parse findings from JSON output
        parse_trivy_severities "${output}"
        total_critical=$((total_critical + TRIVY_CRITICAL))
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
    hook_log "FAIL: $(format_summary ${total_critical} 0 0 0)"
    write_scan_json "$(build_findings_json "trivy" "." "${duration_ms}" "[]" "${total_critical}" 0 0 0)"
fi

exit ${overall_exit}
