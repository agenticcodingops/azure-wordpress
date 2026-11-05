#!/usr/bin/env bash
# gitleaks.sh — Gitleaks secret detection scanner
# Stage: pre-commit | Severity: HIGH (all secrets map to HIGH)
# Scans ONLY staged changes. `git --staged` is the supported form of the
# deprecated `protect --staged` command (hidden since Gitleaks 8.19.0).
# The JSON report is stdout (`--report-path -`). stderr is not part of the report.
# Do NOT emit Match or Secret: with or without --redact, those fields are the
# credential. Rule, file, and line are enough to fix the finding.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Verify tool availability
require_tool "gitleaks" || exit 0

# Check if there are any staged files at all
staged_count="$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null | wc -l)"
if [[ "${staged_count}" -eq 0 ]]; then
    hook_log "PASS: No files staged"
    exit 0
fi

start_timer

hook_log "Scanning... (${staged_count} staged files)"

# `git --staged` with `--report-path -` writes the JSON array to stdout.
# `protect --staged` without `--report-path` writes no JSON, and Gitleaks uses
# exit 1 both for leaks and for a config it cannot load.
gitleaks_cmd=(
    "$SCAN_TOOL" git --staged
    --report-format json
    --report-path -
    --redact
    --no-banner
    --exit-code 1
    --log-level error
)

# Check for config file
config_file="$(resolve_config '.gitleaks.toml' 2>/dev/null || true)"
if [[ -n "${config_file}" ]]; then
    gitleaks_cmd+=(--config "${config_file}")
fi

# Add any extra args passed through
if [[ $# -gt 0 ]]; then
    gitleaks_cmd+=("$@")
fi

stderr_file="$(mktemp)"
report_file="$(mktemp)"
findings_file="$(mktemp)"
details_file="$(mktemp)"
cleanup_gitleaks() {
    rm -f "${stderr_file}" "${report_file}" "${findings_file}" "${details_file}"
}
trap cleanup_gitleaks EXIT

# Keep stderr off the report. A config error is text on stderr and exit 1.
set +e
output="$("${gitleaks_cmd[@]}" 2>"${stderr_file}")"
exit_code=$?
set -e
printf '%s' "${output}" > "${report_file}"

# Used only to tell an empty array from any other array when no parser is
# installed. The compact text is never printed: a findings array can hold a
# credential even after --redact.
report_compact="${output//[[:space:]]/}"

# Windows Git bash mktemp paths are not paths Windows python can open.
to_py_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1"
    else
        printf '%s' "$1"
    fi
}

parse_status=2
total_high=""
py="$(find_python)" || py=""

if [[ -n "${py}" ]]; then
    set +e
    total_high="$("${py}" -I - "$(to_py_path "${report_file}")" "$(to_py_path "${findings_file}")" "$(to_py_path "${details_file}")" <<'PY'
import json
import sys

report_path, findings_path, details_path = sys.argv[1:4]
raw = open(report_path, encoding="utf-8").read().strip()
if not raw:
    sys.exit(2)
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(2)
if not isinstance(data, list):
    sys.exit(2)

findings = []
details = []
for item in data:
    if not isinstance(item, dict) or not isinstance(item.get('RuleID'), str) or not item['RuleID']:
        sys.exit(2)
    rule = str(item.get("RuleID") or "")
    path = str(item.get("File") or "")
    try:
        start = int(item.get("StartLine") or 0)
    except (TypeError, ValueError):
        start = 0
    try:
        end = int(item.get("EndLine") or start)
    except (TypeError, ValueError):
        end = start
    desc = str(item.get("Description") or "")
    findings.append(
        {
            "rule_id": rule,
            "tool": "gitleaks",
            "severity": "HIGH",
            "file": path,
            "line": start,
            "message": desc,
            "fixable": False,
            "fixed": False,
        }
    )
    details.append(f"  HIGH  {rule}  {path}:{start}-{end}")
    if desc:
        details.append(f"    {desc}")

with open(findings_path, "w", encoding="utf-8") as handle:
    json.dump(findings, handle)
with open(details_path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(details))
sys.stdout.write(str(len(findings)))
PY
)"
    parse_status=$?
    set -e
    total_high="${total_high//$'\r'/}"
    total_high="${total_high//$'\n'/}"
elif command -v jq >/dev/null 2>&1; then
    set +e
    jq -e 'type == "array" and all(.[]; type == "object" and (.RuleID | type == "string" and length > 0))' "${report_file}" >/dev/null 2>&1
    parse_status=$?
    set -e
    if [[ ${parse_status} -eq 0 ]]; then
        total_high="$(jq 'length' "${report_file}")"
        # Safe fields only. Never select .Match or .Secret.
        jq -c '[.[] | {rule_id:(.RuleID // ""), tool:"gitleaks", severity:"HIGH", file:(.File // ""), line:(.StartLine // 0), message:(.Description // ""), fixable:false, fixed:false}]' "${report_file}" > "${findings_file}"
        jq -r '.[] | "  HIGH  \(.RuleID)  \(.File):\(.StartLine)-\(.EndLine)", (if .Description then "    \(.Description)" else empty end)' "${report_file}" > "${details_file}"
    fi
else
    # No Python and no jq. `[]` is a clean report. Any other JSON array is a
    # findings report we cannot read: block, and do not copy the report.
    # An unreadable report must never become a clean pass.
    if [[ "${report_compact}" == "[]" ]]; then
        parse_status=0
        total_high=0
    elif [[ "${report_compact}" == \[* ]]; then
        parse_status=0
        total_high=1
        unparsed_message="Gitleaks wrote a JSON findings report, but neither Python nor jq is available, so rule, file, and line were not read. Install Python or jq and scan again."
        printf '%s\n' "[{\"rule_id\":\"gitleaks-report-unparsed\",\"tool\":\"gitleaks\",\"severity\":\"HIGH\",\"file\":\".\",\"line\":0,\"message\":\"${unparsed_message}\",\"fixable\":false,\"fixed\":false}]" > "${findings_file}"
        printf '%s\n' "  HIGH  gitleaks-report-unparsed  .:0-0" "    ${unparsed_message}" > "${details_file}"
        hook_warn "neither Python nor jq is available; blocking because the Gitleaks report was a JSON array and was not printed"
    fi
fi

# Array-shaped corruption may contain findings. Like an unparsed findings
# array, it must block even when infrastructure errors are explicitly tolerated.
if [[ ${parse_status} -ne 0 && "${report_compact}" == \[* ]]; then
    hook_error 'Gitleaks findings report could not be validated; commit blocked'
    exit 1
fi

# Normalize ambiguous exit 1 without findings to an infrastructure error.
if [[ ${parse_status} -ne 0 || ( ${exit_code} -ne 0 && "${total_high:-0}" -eq 0 ) ]]; then
    hook_warn "gitleaks exited ${exit_code} without a complete valid scan"
    handle_exit_code 2
    exit $?
fi

# A valid nonempty report always blocks, even if the tool also failed and the
# adopter explicitly tolerates infrastructure errors. Never discard known leaks.

duration_ms="$(stop_timer)"

if [[ "${total_high}" -eq 0 ]]; then
    hook_log "PASS: No findings above threshold"
    write_scan_json "$(build_pass_json "gitleaks" "." "${duration_ms}")"
    exit 0
fi

hook_log ""
while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    hook_log "${line}"
done < "${details_file}"
hook_log ""
hook_log "FAIL: $(format_summary 0 "${total_high}" 0 0)"
findings_json="$(cat "${findings_file}")"
write_scan_json "$(build_findings_json "gitleaks" "." "${duration_ms}" "${findings_json}" 0 "${total_high}" 0 0)"
exit 1
