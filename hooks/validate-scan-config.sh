#!/usr/bin/env bash
# validate-scan-config.sh — validate scan-config.yaml against its JSON schema
# Stage: pre-commit | Runs only when scan-config.yaml is staged.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Only run when the config itself changed (cheap + relevant).
if ! git diff --cached --name-only --diff-filter=ACMR 2>/dev/null | grep -q 'scan-config\.yaml$'; then
    hook_log "PASS: scan-config.yaml not staged"
    exit 0
fi

PY="$(find_python)" || { hook_warn "python not found - allowing commit (fail-open)"; exit 0; }

start_timer
hook_log "Validating scan-config.yaml against schema..."

set +e
output="$("${PY}" "${REPO_ROOT}/scripts/validate-scan-config.py" "${REPO_ROOT}/scan-config.yaml" 2>&1)"
exit_code=$?
set -e

duration_ms="$(stop_timer)"
echo "${output}"

if [[ ${exit_code} -eq 0 ]]; then
    hook_log "PASS (${duration_ms}ms)"
    exit 0
else
    hook_log "FAIL: scan-config.yaml does not conform to schemas/scan-config.schema.json"
    exit 1
fi
