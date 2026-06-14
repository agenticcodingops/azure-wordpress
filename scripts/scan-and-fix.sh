#!/usr/bin/env bash
# scan-and-fix.sh — shared, versioned scanner (bash twin of scan-and-fix.ps1).
# Used by the Claude Code Stop hook and on demand. Fails open on missing tools,
# fails closed on real findings. With --auto-fix, writes .claude/scan-findings.json.
#
# Usage: scan-and-fix.sh [secrets|semgrep|terraform|all] [--auto-fix]
set -uo pipefail

SCAN_TYPE="${1:-secrets}"
AUTO_FIX=0
[[ "${2:-}" == "--auto-fix" ]] && AUTO_FIX=1

has_errors=0
declare -a TOOLS=() CODES=()

run_secret_scan() {
    command -v trivy >/dev/null 2>&1 || { echo "[scan-and-fix] trivy not found; skipping secrets (fail-open)"; return; }
    trivy fs . --scanners secret --severity CRITICAL,HIGH --exit-code 1 --quiet \
        --skip-dirs node_modules --skip-dirs dist --skip-dirs build \
        --skip-dirs bin --skip-dirs obj --skip-dirs .terraform
    local code=$?
    TOOLS+=("Trivy Secrets"); CODES+=("${code}")
    [[ ${code} -ne 0 ]] && has_errors=1
}

run_semgrep_scan() {
    command -v semgrep >/dev/null 2>&1 || { echo "[scan-and-fix] semgrep not found; skipping (fail-open)"; return; }
    export PYTHONUTF8=1 SEMGREP_SEND_METRICS=off
    semgrep scan --config auto --error --metrics off --quiet
    local code=$?
    TOOLS+=("Semgrep SAST"); CODES+=("${code}")
    [[ ${code} -ne 0 ]] && has_errors=1
}

run_terraform_scan() {
    command -v trivy >/dev/null 2>&1 || return
    trivy config . --severity CRITICAL,HIGH --exit-code 1 --quiet --skip-dirs .terraform
    local code=$?
    TOOLS+=("Trivy IaC"); CODES+=("${code}")
    [[ ${code} -ne 0 ]] && has_errors=1
}

case "${SCAN_TYPE}" in
    secrets)   run_secret_scan ;;
    semgrep)   run_semgrep_scan ;;
    terraform) run_terraform_scan ;;
    all)       run_secret_scan; run_semgrep_scan; run_terraform_scan ;;
    *)         echo "[scan-and-fix] unknown scan type: ${SCAN_TYPE}" >&2; exit 1 ;;  # fail closed
esac

if [[ ${AUTO_FIX} -eq 1 && ${has_errors} -ne 0 ]]; then
    mkdir -p .claude
    {
        echo '{'
        echo '  "schemaVersion": 1,'
        echo "  \"scanType\": \"${SCAN_TYPE}\","
        echo '  "autoFix": true,'
        echo "  \"hasErrors\": true,"
        echo '  "findings": ['
        for i in "${!TOOLS[@]}"; do
            trailing_comma=','
            [[ $i -eq $(( ${#TOOLS[@]} - 1 )) ]] && trailing_comma=''
            passed=$([[ "${CODES[$i]}" -eq 0 ]] && echo true || echo false)
            echo "    {\"tool\": \"${TOOLS[$i]}\", \"exitCode\": ${CODES[$i]}, \"passed\": ${passed}}${trailing_comma}"
        done
        echo '  ]'
        echo '}'
    } > .claude/scan-findings.json
fi

for i in "${!TOOLS[@]}"; do
    status=$([[ "${CODES[$i]}" -eq 0 ]] && echo PASS || echo FAIL)
    echo "[scan-and-fix] ${status} ${TOOLS[$i]} (exit=${CODES[$i]})"
done

[[ ${has_errors} -ne 0 ]] && exit 1 || exit 0
