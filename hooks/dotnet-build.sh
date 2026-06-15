#!/usr/bin/env bash
# dotnet-build.sh — Roslyn analyzers via 'dotnet build'
# Stage: pre-push (slower) | Mode: build the configured solution
#
# Solution + working dir come from scan-config.yaml (languages.csharp.build.*).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_tool "dotnet" || exit 0

# Only run when C# files are staged (push) to avoid building on unrelated pushes.
mapfile -t all_cs < <(get_staged_files cs csproj)
if [[ ${#all_cs[@]} -eq 0 ]]; then
    hook_log "PASS: No C# files staged"
    exit 0
fi

working_dir="$(read_scan_config languages.csharp.build.working_dir '.')"
solution="$(read_scan_config languages.csharp.build.solution '')"
if [[ -z "${solution}" ]]; then
    solution="$(detect_dotnet_solution "${working_dir}")"
    [[ -n "${solution}" && "${working_dir}" != "." ]] && solution="${solution#"${working_dir%/}/"}"
fi
if [[ -z "${solution}" ]]; then
    hook_warn "No .sln/.slnx found under '${working_dir}' (set languages.csharp.build.solution) - allowing push"
    exit 0
fi

start_timer
hook_log "Building (Roslyn analyzers)... (${solution} in ${working_dir})"

build_cmd=(dotnet build "${solution}" /p:AnalysisMode=AllEnabledByDefault --nologo)
[[ $# -gt 0 ]] && build_cmd+=("$@")

set +e
output="$(cd "${working_dir}" && "${build_cmd[@]}" 2>&1)"
exit_code=$?
set -e

duration_ms="$(stop_timer)"

if [[ ${exit_code} -eq 0 ]]; then
    hook_log "PASS: Build + analyzers clean (${duration_ms}ms)"
    write_scan_json "$(build_pass_json "dotnet-build" "${working_dir}" "${duration_ms}")"
    exit 0
else
    # Surface analyzer/build errors
    echo "${output}" | grep -iE 'error|warning' | head -40 || true
    hook_log "FAIL: Build/analyzer errors"
    write_scan_json "$(build_findings_json "dotnet-build" "${working_dir}" "${duration_ms}" "[]" 0 1 0 0)"
    exit 1
fi
