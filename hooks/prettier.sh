#!/usr/bin/env bash
# prettier.sh — Prettier formatting for staged TS/JS/CSS/JSON/MD
# Stage: pre-commit | Mode: staged files only
#
# Runs --write (auto-format). Under Lefthook use stage_fixed:true to re-stage;
# under pre-commit a modified file fails the hook so you re-stage and re-commit.
# Working dir comes from scan-config.yaml (languages.typescript.build.working_dir).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

mapfile -t all_files < <(get_staged_files ts tsx js jsx json css scss md)
if [[ ${#all_files[@]} -eq 0 ]]; then
    hook_log "PASS: No formattable files staged"
    exit 0
fi

working_dir="$(read_scan_config languages.typescript.build.working_dir '.')"
files=()
for f in "${all_files[@]}"; do
    if [[ "${working_dir}" == "." ]]; then
        files+=("${f}")
    elif [[ "${f}" == "${working_dir%/}/"* ]]; then
        files+=("${f#${working_dir%/}/}")
    fi
done
[[ ${#files[@]} -eq 0 ]] && { hook_log "PASS: No staged files under '${working_dir}'"; exit 0; }

# Fail-open if the configured working_dir doesn't exist on disk — otherwise a runner
# gets selected and the later `cd "${working_dir}"` exits 1, which we'd misread as a
# format failure and BLOCK the commit. A missing dir is an infra error, not a finding.
[[ -d "${working_dir}" ]] || { hook_warn "prettier: working_dir '${working_dir}' not found - allowing commit (fail-open)"; exit 0; }

runner=()
if [[ -x "${working_dir%/}/node_modules/.bin/prettier" ]]; then
    runner=("${working_dir%/}/node_modules/.bin/prettier")
elif command -v prettier >/dev/null 2>&1; then
    runner=(prettier)
elif command -v npx >/dev/null 2>&1 && \
     (cd "${working_dir}" && npx --no-install prettier --version >/dev/null 2>&1); then
    # Only use the npx fallback once we've confirmed prettier is actually runnable
    # (--no-install errors instead of installing) — otherwise fail open below.
    runner=(npx --no-install prettier)
else
    hook_warn "prettier not found (no node_modules/.bin/prettier, prettier, or runnable npx prettier) - allowing commit (fail-open)"
    exit 0
fi

start_timer
hook_log "Formatting... (${#files[@]} files in ${working_dir})"

prettier_cmd=("${runner[@]}" --write --ignore-unknown)
[[ $# -gt 0 ]] && prettier_cmd+=("$@")
prettier_cmd+=("${files[@]}")

set +e
output="$(cd "${working_dir}" && "${prettier_cmd[@]}" 2>&1)"
exit_code=$?
set -e

duration_ms="$(stop_timer)"

if [[ ${exit_code} -eq 0 ]]; then
    hook_log "PASS: Prettier formatted (${duration_ms}ms)"
    write_scan_json "$(build_pass_json "prettier" "${working_dir}" "${duration_ms}")"
    exit 0
else
    echo "${output}"
    hook_log "FAIL: Prettier error (syntax?)"
    write_scan_json "$(build_findings_json "prettier" "${working_dir}" "${duration_ms}" "[]" 0 0 1 0)"
    exit 1
fi
