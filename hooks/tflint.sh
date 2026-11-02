#!/usr/bin/env bash
# tflint.sh — TFLint Terraform linter
# Stage: pre-push | Severity: per config
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

run_push_snapshot "$@"

# Verify tool availability
require_tool "tflint" || exit 0

start_timer

# Detect Terraform directories in the selected object tree.
read_nul_paths scan_dirs detect_changed_dirs

if [[ ${#scan_dirs[@]} -eq 0 ]]; then
    hook_log "PASS: No Terraform files selected"
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

    # Configuration and plugin cache are provisioned outside the scanned checkout.
    config_file="${SCAN_TFLINT_CONFIG:-}"
    [[ -f "$config_file" ]] || { hook_error 'SCAN_TFLINT_CONFIG must name a trusted external config'; exit 1; }
    assert_external_path "$config_file"
    [[ "$config_file" == *.hcl ]] || { hook_error 'Trusted config must end in .hcl'; exit 1; }
    config_text="$(< "$config_file")"
    [[ "$config_text" != *plugin_dir* ]] || { hook_error 'Remove plugin_dir; use SCAN_TFLINT_PLUGIN_DIR'; exit 1; }
    export TFLINT_PLUGIN_DIR="${SCAN_TFLINT_PLUGIN_DIR:-}"
    [[ -n "$TFLINT_PLUGIN_DIR" ]] || { hook_error 'Set SCAN_TFLINT_PLUGIN_DIR to an external plugin cache'; exit 1; }
    assert_external_path "$TFLINT_PLUGIN_DIR"
    assert_safe_write_path "$TFLINT_PLUGIN_DIR"
    [[ $# -eq 0 ]] || { hook_error 'TFLint extra arguments are disabled'; exit 1; }
    tflint_cmd+=(--config "$config_file")

    # Initialize tflint plugins (required before scanning)
    set +e
    init_cmd=(tflint --chdir="${dir}" --init)
    if [[ -n "${config_file}" ]]; then
        init_cmd+=(--config "${config_file}")
    fi
    "${init_cmd[@]}" >/dev/null 2>&1
    init_exit=$?
    set -e
    if [[ "$init_exit" -ne 0 ]]; then hook_error "TFLint initialization failed"; exit 1; fi

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
    elif [[ ${exit_code} -ne 0 ]]; then
        # Operational statuses (including 1) use the shared infrastructure contract.
        handle_exit_code 2 || exit 1
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
