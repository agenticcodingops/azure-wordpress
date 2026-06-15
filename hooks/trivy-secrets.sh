#!/usr/bin/env bash
# trivy-secrets.sh — Trivy secret detection scanner
# Stage: pre-commit | Mode: scan ONLY staged file content | --skip-db-update
# Exports staged content to a temp directory so only changed files are scanned.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Verify tool availability
require_tool "trivy" || exit 0

# Get list of staged files (all types — secrets can be in any file).
# NUL-delimited (-z + mapfile -d '') so filenames containing newlines can't
# escape the scan.
mapfile -d '' -t staged_files < <(git diff --cached --name-only -z --diff-filter=ACMR 2>/dev/null)

if [[ ${#staged_files[@]} -eq 0 ]]; then
    hook_log "PASS: No files staged"
    exit 0
fi

start_timer

hook_log "Scanning... (${#staged_files[@]} staged files)"

# Create temp dir with ONLY staged file content — avoids scanning entire repo
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

skipped=0
for file in "${staged_files[@]}"; do
    # Create parent directories in temp
    file_dir="$(dirname "${file}")"
    if [[ "${file_dir}" != "." ]]; then
        mkdir -p "${tmpdir}/${file_dir}"
    fi
    # Export staged content (from git index). On failure, count + warn so secret-scan
    # coverage gaps are visible rather than silently dropped.
    if ! git show ":${file}" > "${tmpdir}/${file}" 2>/dev/null; then
        skipped=$((skipped + 1))
        hook_warn "could not export staged '${file}' for secret scan (skipped)"
    fi
done
[[ ${skipped} -gt 0 ]] && hook_warn "${skipped} staged file(s) skipped from the secret scan"

# Build Trivy command — scan the temp dir (contains only staged files)
trivy_cmd=(trivy fs "${tmpdir}" --scanners secret --exit-code 1 --format json --skip-db-update --quiet)

# Add any extra args passed through
if [[ $# -gt 0 ]]; then
    trivy_cmd+=("$@")
fi

# Run Trivy with retry logic
set +e
output="$(run_trivy_with_retry "${trivy_cmd[@]}")"
exit_code=$?
set -e

total_critical=0
total_high=0
total_medium=0
total_low=0

if [[ ${exit_code} -eq 1 ]]; then
    # Parse findings from JSON output
    parse_trivy_secret_severities "${output}"
    total_critical=$((TRIVY_CRITICAL))
    total_high=$((TRIVY_HIGH))
    total_medium=$((TRIVY_MEDIUM))
    total_low=$((TRIVY_LOW))
    # Show actionable details so developers know what to fix
    print_trivy_secret_findings "${output}"
elif [[ ${exit_code} -ge 2 ]]; then
    # Infrastructure error — fail-open
    handle_exit_code ${exit_code}
    exit_code=0
fi

duration_ms="$(stop_timer)"

if [[ ${exit_code} -eq 0 ]]; then
    hook_log "PASS: No findings above threshold"
    write_scan_json "$(build_pass_json "trivy" "." "${duration_ms}")"
else
    hook_log "FAIL: $(format_summary ${total_critical} ${total_high} ${total_medium} ${total_low})"
    write_scan_json "$(build_findings_json "trivy" "." "${duration_ms}" "[]" "${total_critical}" "${total_high}" "${total_medium}" "${total_low}")"
fi

exit ${exit_code}
