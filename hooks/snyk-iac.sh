#!/usr/bin/env bash
# snyk-iac.sh — Snyk IaC scan for Terraform misconfigurations
# Stage: pre-push | Severity: all | Optional: blocks if not installed, skips if not authenticated
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

run_push_snapshot "$@"

# Print actionable details for Snyk IaC findings so developers know what to fix.
# Mirrors print_tflint_findings / print_checkov_findings in lib/common.sh.
# Usage: print_snyk_iac_findings "$json_output"
print_snyk_iac_findings() {
    local json="${1:-}"
    if [[ -z "${json}" ]] || ! command -v jq >/dev/null 2>&1; then
        hook_log "  (install jq to see finding details)"
        return 0
    fi

    local findings
    findings="$(echo "${json}" | jq -r "$SCAN_SEVERITY_JQ"'
        [.infrastructureAsCodeIssues[]? |
         {severity: (.severity | normalized("snyk")), id: (.id // .publicId // ""),
          title: (.title // .iacDescription.issue // ""),
          file: (.targetFile // .path // ""),
          line: (.lineNumber // 0), resolve: (.resolve // .iacDescription.resolve // "")}] |
        sort_by(if .severity == "CRITICAL" then 0 elif .severity == "HIGH" then 1
                elif .severity == "MEDIUM" then 2 else 3 end) |
        .[] |
        "  \(.severity | ascii_upcase)  \(.id)  \(.file):\(.line)\n    \(.title)\(if .resolve != "" then "\n    Fix: \(.resolve)" else "" end)"
    ' 2>/dev/null)" || true

    if [[ -n "${findings}" ]]; then
        hook_log ""
        while IFS= read -r line; do
            hook_log "${line}"
        done <<< "${findings}"
        hook_log ""
    fi
}

# Verify tool availability (a missing CLI blocks unless SCAN_ALLOW_TOOL_ERRORS=1)
require_tool "snyk" || exit 0

# Deliberate skip: no SNYK_TOKEN and no login. An invalid token is not skipped; its scan error blocks.
if [[ -z "${SNYK_TOKEN:-}" ]]; then
    set +e
    "$SCAN_TOOL" whoami >/dev/null 2>&1
    whoami_exit=$?
    set -e
    if [[ ${whoami_exit} -ne 0 ]]; then
        hook_warn "Snyk not authenticated (no SNYK_TOKEN and 'snyk whoami' failed) — allowing push (fail-open)"
        exit 0
    fi
fi

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
total_critical=0
total_high=0
total_medium=0
total_low=0

for dir in "${scan_dirs[@]}"; do
    if [[ ! -d "${dir}" ]]; then
        continue
    fi

    # Build Snyk command as array
    snyk_cmd=("$SCAN_TOOL" iac test --json)

    # Check for .snyk policy file in repo root
    if [[ -f ".snyk" ]]; then
        snyk_cmd+=(--policy-path="$(pwd)")
    fi

    # Add any extra args passed through
    if [[ $# -gt 0 ]]; then
        snyk_cmd+=("$@")
    fi

    # Run Snyk
    set +e
    output="$(cd -- "${dir}" && "${snyk_cmd[@]}" 2>&1)"
    exit_code=$?
    set -e

    if [[ ${exit_code} -eq 1 ]]; then
        # Parse findings from JSON output
        read -r local_critical local_high local_medium local_low < <(scanner_severity_counts "${output}" snyk)
        total_critical=$((total_critical + local_critical))
        total_high=$((total_high + local_high))
        total_medium=$((total_medium + local_medium))
        total_low=$((total_low + local_low))
        # Surface the parsed findings (file, severity, title, fix) before failing.
        print_snyk_iac_findings "${output}"
        overall_exit=1
    elif [[ ${exit_code} -ge 2 ]]; then
        # Exit 2 or higher is a tool error: blocks unless SCAN_ALLOW_TOOL_ERRORS=1
        handle_exit_code ${exit_code}
    fi
done

duration_ms="$(stop_timer)"

if [[ ${overall_exit} -eq 0 ]]; then
    hook_log "PASS: No findings above threshold"
    write_scan_json "$(build_pass_json "snyk" "." "${duration_ms}")"
else
    hook_log "FAIL: $(format_summary ${total_critical} ${total_high} ${total_medium} ${total_low})"
    write_scan_json "$(build_findings_json "snyk" "." "${duration_ms}" "[]" "${total_critical}" "${total_high}" "${total_medium}" "${total_low}")"
fi

exit ${overall_exit}
