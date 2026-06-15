#!/usr/bin/env bash
# eslint.sh — ESLint for staged TS/JS (auto-fix + gate on remaining errors)
# Stage: pre-commit | Mode: staged ts/tsx/js/jsx only
#
# Working dir comes from scan-config.yaml (languages.typescript.build.working_dir).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

mapfile -t all_ts < <(get_staged_files ts tsx js jsx)
if [[ ${#all_ts[@]} -eq 0 ]]; then
    hook_log "PASS: No TS/JS files staged"
    exit 0
fi

working_dir="$(read_scan_config languages.typescript.build.working_dir '.')"

# Relativize staged paths to working_dir.
files=()
for f in "${all_ts[@]}"; do
    if [[ "${working_dir}" == "." ]]; then
        files+=("${f}")
    elif [[ "${f}" == "${working_dir%/}/"* ]]; then
        files+=("${f#${working_dir%/}/}")
    fi
done
[[ ${#files[@]} -eq 0 ]] && { hook_log "PASS: No staged TS/JS under '${working_dir}'"; exit 0; }

# Fail-open if the configured working_dir doesn't exist on disk — otherwise a runner
# gets selected and the later `cd "${working_dir}"` exits 1, which we'd misread as a
# lint failure and BLOCK the commit. A missing dir is an infra error, not a finding.
[[ -d "${working_dir}" ]] || { hook_warn "eslint: working_dir '${working_dir}' not found - allowing commit (fail-open)"; exit 0; }

# Resolve an eslint runner; fail-open (skip) if the consumer has no eslint set up.
runner=()
if [[ -x "${working_dir%/}/node_modules/.bin/eslint" ]]; then
    runner=("${working_dir%/}/node_modules/.bin/eslint")
elif command -v eslint >/dev/null 2>&1; then
    runner=(eslint)
elif command -v npx >/dev/null 2>&1 && \
     (cd "${working_dir}" && npx --no-install eslint --version >/dev/null 2>&1); then
    # Only use the npx fallback once we've confirmed eslint is actually runnable
    # (--no-install errors instead of installing) — otherwise fail open below.
    runner=(npx --no-install eslint)
else
    hook_warn "eslint not found (no node_modules/.bin/eslint, eslint, or runnable npx eslint) - allowing commit (fail-open)"
    exit 0
fi

start_timer
hook_log "Linting... (${#files[@]} TS/JS files in ${working_dir})"

eslint_cmd=("${runner[@]}" --fix)
[[ $# -gt 0 ]] && eslint_cmd+=("$@")
eslint_cmd+=("${files[@]}")

set +e
output="$(cd "${working_dir}" && "${eslint_cmd[@]}" 2>&1)"
exit_code=$?
set -e

duration_ms="$(stop_timer)"

if [[ ${exit_code} -eq 0 ]]; then
    hook_log "PASS: ESLint clean (${duration_ms}ms)"
    write_scan_json "$(build_pass_json "eslint" "${working_dir}" "${duration_ms}")"
    exit 0
elif [[ ${exit_code} -eq 1 ]]; then
    echo "${output}"
    hook_log "FAIL: ESLint errors remain (some may have been auto-fixed; re-stage)"
    write_scan_json "$(build_findings_json "eslint" "${working_dir}" "${duration_ms}" "[]" 0 1 0 0)"
    exit 1
else
    handle_exit_code ${exit_code}
    exit 0
fi
