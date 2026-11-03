#!/usr/bin/env bash
# Validate the consumer index using the package-owned validator and schema.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
PY="$(find_python)" || {
    [[ "${SCAN_ALLOW_TOOL_ERRORS:-0}" == 1 ]] && exit 0
    hook_error 'Python is required to validate staged scan-config.yaml'
    exit 1
}
exec "$PY" "${SCRIPT_DIR}/../scripts/validate-scan-config.py" --staged
