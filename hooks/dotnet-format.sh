#!/usr/bin/env bash
# dotnet-format.sh — .NET formatting check (dotnet format --verify-no-changes)
# Stage: pre-commit | Mode: staged .cs only
#
# Solution + working dir come from scan-config.yaml (languages.csharp.build.*),
# never hardcoded — this is the generic fix for the api/ path bug. Empty solution
# => auto-detect nearest .slnx/.sln under the working dir.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_tool "dotnet" || exit 0

mapfile -t all_cs < <(get_staged_files cs)
if [[ ${#all_cs[@]} -eq 0 ]]; then
    hook_log "PASS: No C# files staged"
    exit 0
fi

# Resolve build settings from config (with safe defaults).
working_dir="$(read_scan_config languages.csharp.build.working_dir '.')"
solution="$(read_scan_config languages.csharp.build.solution '')"

# Filter staged files to those under working_dir and make them relative to it.
include_files=()
for f in "${all_cs[@]}"; do
    if [[ "${working_dir}" == "." ]]; then
        include_files+=("${f}")
    elif [[ "${f}" == "${working_dir%/}/"* ]]; then
        include_files+=("${f#${working_dir%/}/}")
    fi
done
if [[ ${#include_files[@]} -eq 0 ]]; then
    hook_log "PASS: No staged C# files under working_dir '${working_dir}'"
    exit 0
fi

# Auto-detect solution if not configured.
if [[ -z "${solution}" ]]; then
    solution="$(detect_dotnet_solution "${working_dir}")"
    # Make detected solution path relative to working_dir.
    [[ -n "${solution}" && "${working_dir}" != "." ]] && solution="${solution#${working_dir%/}/}"
fi
if [[ -z "${solution}" ]]; then
    hook_warn "No .sln/.slnx found under '${working_dir}' (set languages.csharp.build.solution) - allowing commit"
    exit 0
fi

start_timer
hook_log "Checking format... (${#include_files[@]} files, ${solution} in ${working_dir})"

format_cmd=(dotnet format "${solution}" --verify-no-changes --no-restore)
for inc in "${include_files[@]}"; do
    format_cmd+=(--include "${inc}")
done
[[ $# -gt 0 ]] && format_cmd+=("$@")

set +e
output="$(cd "${working_dir}" && "${format_cmd[@]}" 2>&1)"
exit_code=$?
set -e

duration_ms="$(stop_timer)"

if [[ ${exit_code} -eq 0 ]]; then
    hook_log "PASS: Formatting OK (${duration_ms}ms)"
    write_scan_json "$(build_pass_json "dotnet-format" "${working_dir}" "${duration_ms}")"
    exit 0
else
    echo "${output}"
    hook_log "FAIL: Formatting needed — run 'dotnet format ${solution}' in ${working_dir}"
    write_scan_json "$(build_findings_json "dotnet-format" "${working_dir}" "${duration_ms}" "[]" 0 0 1 0)"
    exit 1
fi
