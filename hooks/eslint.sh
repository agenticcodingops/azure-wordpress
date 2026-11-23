#!/usr/bin/env bash
# eslint.sh — ESLint for staged TS/JS (auto-fix + gate on remaining errors)
# Stage: pre-commit | Mode: staged ts/tsx/js/jsx only
#
# Working dir comes from scan-config.yaml (languages.typescript.build.working_dir).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# An incomplete scan blocks. With the explicit local opt-in it warns and returns.
scan_incomplete() {
    if [[ "${SCAN_ALLOW_TOOL_ERRORS:-0}" == 1 ]]; then
        hook_warn "eslint: $1; scan incomplete, explicit local fail-open opt-in (SCAN_ALLOW_TOOL_ERRORS=1)"
        return 0
    fi
    hook_error "eslint: $1; scan incomplete. $2"
    exit 1
}

# Read NUL-delimited staged paths. Print 'inside', 'outside', or nothing for a missing
# directory: see lib/working_dir.py.
inspect_working_dir() {
    local py
    py="$(find_python)" || return 1
    "$py" -B -E -P "${SCRIPT_DIR}/lib/working_dir.py" "${SCAN_CONFIG_FILE:-scan-config.yaml}"
}

read_nul_paths all_ts get_staged_files ts tsx js jsx
if [[ ${#all_ts[@]} -eq 0 ]]; then
    hook_log "PASS: No TS/JS files staged"
    exit 0
fi

working_dir="$(read_scan_config languages.typescript.build.working_dir '.')"
missing_dir="working_dir '${working_dir}' is not an existing directory"
fix_dir="Fix languages.typescript.build.working_dir in scan-config.yaml."

# Check before the prefix filter, which would report a missing directory as a PASS.
dir_state=""
if [[ "${working_dir}" != "." ]]; then
    dir_state="$(printf '%s\0' "${all_ts[@]}" | inspect_working_dir)" || dir_state=""
    [[ -n "${dir_state}" || -d "${working_dir}" ]] || scan_incomplete "${missing_dir}" "${fix_dir}"
fi

# Relativize staged paths to working_dir.
files=()
for f in "${all_ts[@]}"; do
    if [[ "${working_dir}" == "." ]]; then
        files+=("${f}")
    elif [[ "${f}" == "${working_dir%/}/"* ]]; then
        files+=("${f#${working_dir%/}/}")
    fi
done
if [[ ${#files[@]} -eq 0 ]]; then
    if [[ "${dir_state}" == inside* ]]; then
        hook_warn "eslint: nothing under working_dir '${working_dir}' was selected, so nothing was linted. Write the value exactly as Git spells the directory, or '.' for the repository root."
    else
        hook_log "PASS: No staged TS/JS under '${working_dir}'"
    fi
    exit 0
fi

# The cd below needs the directory exactly as configured. With the opt-in, skip here:
# a failed cd would otherwise be misread as a lint failure.
[[ -d "${working_dir}" ]] || { scan_incomplete "${missing_dir}" "${fix_dir}"; exit 0; }

# Resolve a runner; finding none is an incomplete scan.
# Repository binaries and executable configs require explicit trust.
if [[ "${SCAN_TRUST_REPO_CODE:-0}" == 1 ]]; then
runner=()
if [[ -x "${working_dir%/}/node_modules/.bin/eslint" ]]; then
    runner=("${working_dir%/}/node_modules/.bin/eslint")
elif command -v eslint >/dev/null 2>&1; then
    runner=(eslint)
elif command -v npx >/dev/null 2>&1 && \
     (cd "${working_dir}" && npx --no-install eslint --version >/dev/null 2>&1); then
    # Only use the npx fallback once we've confirmed eslint is actually runnable
    # (--no-install errors instead of installing) — otherwise the scan is incomplete.
    runner=(npx --no-install eslint)
else
    scan_incomplete "no eslint runner found (node_modules/.bin/eslint, eslint on PATH, or runnable npx eslint)" \
        "Provision the eslint runner: install it in '${working_dir}' (node_modules) or put it on PATH."
    exit 0
fi

else
    require_trusted_app_tool eslint
fi

start_timer
hook_log "Linting... (${#files[@]} TS/JS files in ${working_dir})"

eslint_cmd=("${runner[@]}" --fix)
if [[ "${SCAN_TRUST_REPO_CODE:-0}" != 1 ]]; then
    [[ $# -eq 0 ]] || { hook_error "Extra arguments require SCAN_TRUST_REPO_CODE=1"; exit 1; }
    eslint_cmd+=(--config "$trusted_config" --no-config-lookup)
fi
for file in "${files[@]}"; do assert_safe_write_path "${working_dir%/}/$file"; done
[[ $# -gt 0 ]] && eslint_cmd+=("$@")
eslint_cmd+=(-- "${files[@]}")

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
