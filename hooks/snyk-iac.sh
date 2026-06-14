#!/usr/bin/env bash
# snyk-iac.sh — Snyk IaC scan for Terraform misconfigurations
# Stage: pre-push | Severity: all | Optional: fail-open if not installed/authenticated
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Verify tool availability (fail-open if snyk not installed)
require_tool "snyk" || exit 0

# Verify authentication (fail-open if not authenticated)
if [[ -z "${SNYK_TOKEN:-}" ]]; then
    set +e
    snyk whoami >/dev/null 2>&1
    whoami_exit=$?
    set -e
    if [[ ${whoami_exit} -ne 0 ]]; then
        hook_warn "Snyk not authenticated (no SNYK_TOKEN and 'snyk whoami' failed) — allowing push (fail-open)"
        exit 0
    fi
fi

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

    # Build Snyk command as array
    snyk_cmd=(snyk iac test "${dir}" --json)

    # Check for .snyk policy file in repo root
    if [[ -f ".snyk" ]]; then
        snyk_cmd+=(--policy-path=.)
    fi

    # Add any extra args passed through
    if [[ $# -gt 0 ]]; then
        snyk_cmd+=("$@")
    fi

    # Run Snyk
    set +e
    output="$("${snyk_cmd[@]}" 2>&1)"
    exit_code=$?
    set -e

    if [[ ${exit_code} -eq 1 ]]; then
        # Parse findings from JSON output
        if command -v jq >/dev/null 2>&1; then
            local_critical="$(echo "${output}" | jq '[.infrastructureAsCodeIssues[]? | select(.severity == "critical")] | length' 2>/dev/null || echo 0)"
            local_high="$(echo "${output}" | jq '[.infrastructureAsCodeIssues[]? | select(.severity == "high")] | length' 2>/dev/null || echo 0)"
            local_medium="$(echo "${output}" | jq '[.infrastructureAsCodeIssues[]? | select(.severity == "medium")] | length' 2>/dev/null || echo 0)"
            local_low="$(echo "${output}" | jq '[.infrastructureAsCodeIssues[]? | select(.severity == "low")] | length' 2>/dev/null || echo 0)"
            total_critical=$((total_critical + local_critical))
            total_high=$((total_high + local_high))
            total_medium=$((total_medium + local_medium))
            total_low=$((total_low + local_low))
        else
            total_high=$((total_high + 1))
        fi
        overall_exit=1
    elif [[ ${exit_code} -ge 2 ]]; then
        # Infrastructure error — fail-open
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
