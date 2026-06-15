#!/usr/bin/env bash
# sqlfluff.sh — SQLFluff linting for staged .sql files
# Stage: pre-commit | Mode: staged .sql only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_tool "sqlfluff" || exit 0

mapfile -t files < <(get_staged_files sql)
if [[ ${#files[@]} -eq 0 ]]; then
    hook_log "PASS: No SQL files staged"
    exit 0
fi

# Respect a project .sqlfluff config (a CLI --dialect would OVERRIDE it); only force a
# default dialect when no config is present.
sqlfluff_cmd=(sqlfluff lint)
dialect_note="from .sqlfluff"
if [[ ! -f .sqlfluff ]]; then
    sqlfluff_cmd+=(--dialect ansi)
    dialect_note="ansi (default; no .sqlfluff)"
fi

start_timer
hook_log "Linting... (${#files[@]} SQL files, dialect=${dialect_note})"
[[ $# -gt 0 ]] && sqlfluff_cmd+=("$@")
sqlfluff_cmd+=("${files[@]}")

set +e
output="$("${sqlfluff_cmd[@]}" 2>&1)"
exit_code=$?
set -e

duration_ms="$(stop_timer)"

if [[ ${exit_code} -eq 0 ]]; then
    hook_log "PASS: SQLFluff clean (${duration_ms}ms)"
    write_scan_json "$(build_pass_json "sqlfluff" "." "${duration_ms}")"
    exit 0
elif [[ ${exit_code} -eq 1 ]]; then
    echo "${output}"
    hook_log "FAIL: SQLFluff lint issues"
    write_scan_json "$(build_findings_json "sqlfluff" "." "${duration_ms}" "[]" 0 0 1 0)"
    exit 1
else
    handle_exit_code ${exit_code}
    exit 0
fi
