#!/usr/bin/env python3
"""AI agent scanning interface for Terraform security scanning.

Runs Trivy and/or Checkov against Terraform directories, normalizes results
into a unified JSON format, and writes the agent report to .scanning/last-scan.json.

Supports auto-fix via Checkov --fix, severity filtering, baseline/suppression
awareness, and both text and JSON output formats.

Usage:
    python scripts/scan.py                                     # scan current dir
    python scripts/scan.py terraform/                          # scan specific dir
    python scripts/scan.py --format json                       # JSON output
    python scripts/scan.py --auto-fix                          # apply Checkov fixes
    python scripts/scan.py --severity CRITICAL,HIGH,MEDIUM     # filter by severity
    python scripts/scan.py --tools trivy                       # only run Trivy

Exit Codes:
    0 - No findings above threshold
    1 - Findings detected above threshold
    2 - Tool error (ambiguous -- signal to caller per CLI contract)
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from safe_io import write_text
from scan_policy import apply_exceptions, occurrence_fingerprint, suppression_file, load_suppression_entries, baseline_keys, scanner_path
from scan_reports import validate_report

# Severity normalization mappings
TRIVY_SEVERITY_MAP = {
    "CRITICAL": "CRITICAL",
    "HIGH": "HIGH",
    "MEDIUM": "MEDIUM",
    "LOW": "LOW",
    "UNKNOWN": "LOW",
}

CHECKOV_SEVERITY_MAP = {
    "CRITICAL": "CRITICAL",
    "HIGH": "HIGH",
    "MEDIUM": "MEDIUM",
    "LOW": "LOW",
}

SNYK_SEVERITY_MAP = {
    "critical": "CRITICAL",
    "high": "HIGH",
    "medium": "MEDIUM",
    "low": "LOW",
}

SEVERITY_ORDER = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3}


def resolve_tool(name):
    """Resolve a tool's full path, handling Windows pip-installed scripts."""
    resolved = shutil.which(name)
    if resolved:
        return resolved
    # On Windows, pip installs to Scripts/ which may not resolve without .exe
    if sys.platform == "win32":
        for ext in [".exe", ".cmd", ".bat"]:
            resolved = shutil.which(name + ext)
            if resolved:
                return resolved
    return name


def run_cmd(cmd, timeout=300):
    """Run a command and return (returncode, stdout, stderr)."""
    # Resolve the tool path for the first element
    cmd = list(cmd)
    cmd[0] = resolve_tool(cmd[0])
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return 2, "", "Command timed out"
    except FileNotFoundError:
        return 2, "", f"Command not found: {cmd[0]}"


def detect_cloud_provider(scan_dir):
    """Auto-detect cloud provider from .scanning/configs/ or Terraform files."""
    # Check .scanning/configs/ for provider-specific config files
    scanning_dir = Path(scan_dir)
    while scanning_dir != scanning_dir.parent:
        config_dir = scanning_dir / ".scanning" / "configs"
        if config_dir.is_dir():
            for f in config_dir.iterdir():
                name = f.name.lower()
                if "aws" in name:
                    return "aws"
                if "azure" in name or "azurerm" in name:
                    return "azure"
                if "gcp" in name or "google" in name:
                    return "gcp"
        scanning_dir = scanning_dir.parent

    # Scan Terraform files for provider blocks
    scan_path = Path(scan_dir)
    for tf_file in scan_path.rglob("*.tf"):
        try:
            content = tf_file.read_text(encoding="utf-8", errors="ignore")
            if '"aws"' in content or "provider \"aws\"" in content:
                return "aws"
            if '"azurerm"' in content or "provider \"azurerm\"" in content:
                return "azure"
            if '"google"' in content or "provider \"google\"" in content:
                return "gcp"
        except OSError:
            continue

    return None


def count_by_severity(findings):
    """Count findings by severity level."""
    counts = {"CRITICAL": 0, "HIGH": 0, "MEDIUM": 0, "LOW": 0}
    for f in findings:
        sev = f.get("severity", "LOW")
        if sev in counts:
            counts[sev] += 1
    return counts


def count_by_tool(findings):
    """Count findings by tool name."""
    counts = {}
    for f in findings:
        tool = f.get("tool", "unknown")
        counts[tool] = counts.get(tool, 0) + 1
    return counts


def map_trivy_severity(raw_severity):
    """Map Trivy severity to normalized severity."""
    return TRIVY_SEVERITY_MAP.get(raw_severity, "LOW")


def map_checkov_severity(raw_severity):
    """Map Checkov severity to normalized severity."""
    return CHECKOV_SEVERITY_MAP.get(raw_severity, "MEDIUM")


def map_snyk_severity(raw_severity):
    """Map Snyk severity (lowercase) to normalized severity."""
    return SNYK_SEVERITY_MAP.get(raw_severity.lower() if raw_severity else "", "MEDIUM")


def generate_remediation_url(tool, rule_id):
    """Generate a remediation documentation URL for a finding."""
    if tool == "checkov" and rule_id:
        return f"https://docs.checkov.io/docs/{rule_id}"
    if tool == "trivy" and rule_id:
        return f"https://avd.aquasec.com/misconfig/{rule_id.lower()}"
    if tool == "snyk" and rule_id:
        return f"https://security.snyk.io/rules/cloud/{rule_id}"
    return ""


def run_trivy(scan_dir, severity_filter=None):
    """Run Trivy IaC scan and return normalized findings."""
    findings = []

    cmd = [
        "trivy", "config",
        "--format", "json",
        "--skip-check-update",
        "--include-non-failures",
        "--exit-code", "0",
    ]

    if severity_filter:
        cmd.extend(["--severity", ",".join(severity_filter)])

    cmd.extend(["--", str(scan_dir)])
    rc, stdout, stderr = run_cmd(cmd)

    if rc != 0:
        # Infrastructure error - fail-open
        print(f"  [WARN] Trivy scan failed (exit {rc}): {stderr.strip()[:200]}", file=sys.stderr)
        return findings, True  # error flag

    try:
        data = validate_report(json.loads(stdout), "trivy")
    except (ValueError, TypeError):
        print(f"  [WARN] Trivy returned invalid JSON", file=sys.stderr)
        return findings, True

    # Parse Trivy JSON output
    results = data.get("Results", [])
    for result in results:
        target = result.get("Target", "")
        misconfigs = result.get("Misconfigurations", [])
        for mc in misconfigs:
            if mc.get("Status") == "PASS":
                continue
            raw_severity = mc.get("Severity", "UNKNOWN")
            normalized = map_trivy_severity(raw_severity)
            rule_id = mc.get("AVDID") or mc.get("ID", "")

            line_val = mc.get("CauseMetadata", {}).get("StartLine", 0)
            finding = {
                "rule_id": rule_id,
                "tool": "trivy",
                "severity": normalized,
                "file": scanner_path(target, "trivy", policy_root(scan_dir), scan_dir),
                "reported_file": target,
                "message": mc.get("Title", mc.get("Description", "")),
                "resource": mc.get("CauseMetadata", {}).get("Resource", ""),
                "end_line": mc.get("CauseMetadata", {}).get("EndLine", line_val),
                "remediation_url": generate_remediation_url("trivy", rule_id),
                "fixable": False,
                "fixed": False,
            }
            if line_val and line_val > 0:
                finding["line"] = line_val
            findings.append(finding)

    return findings, False


def run_checkov(scan_dir, auto_fix=False, config_file=None):
    """Run Checkov scan and return normalized findings."""
    findings = []

    cmd = [
        "checkov",
        "--directory", str(scan_dir),
        "--output", "json",
        "--compact",
        "--quiet",
    ]

    if config_file and Path(config_file).exists():
        cmd.extend(["--config-file", str(config_file)])

    if auto_fix:
        cmd.append("--fix")

    rc, stdout, stderr = run_cmd(cmd, timeout=600)

    if rc not in (0, 1):
        print(f"  [WARN] Checkov scan failed (exit {rc}): {stderr.strip()[:200]}", file=sys.stderr)
        return findings, True, 0  # error flag, fix count

    fix_count = 0

    try:
        # Checkov can output an array or a single object
        data = validate_report(json.loads(stdout), "checkov")
        if isinstance(data, dict):
            data = [data]
    except (ValueError, TypeError):
        print(f"  [WARN] Checkov returned invalid JSON", file=sys.stderr)
        return findings, True, 0

    for check_type in data:
        if not isinstance(check_type, dict):
            continue

        failed_checks = check_type["results"]["failed_checks"] + check_type["results"].get("skipped_checks", [])
        for check in failed_checks:
            rule_id = check.get("check_id", "")
            raw_severity = check.get("severity", "MEDIUM")
            normalized = map_checkov_severity(raw_severity) if raw_severity else "MEDIUM"

            is_fixable = check.get("fixed", False) or check.get("fixable", False)
            is_fixed = check.get("fixed", False)
            if is_fixed:
                fix_count += 1

            line_val = check.get("file_line_range", [0])[0] if check.get("file_line_range") else 0
            finding = {
                "rule_id": rule_id,
                "tool": "checkov",
                "severity": normalized,
                "file": scanner_path(check.get("file_path", ""), "checkov", policy_root(scan_dir), scan_dir),
                "reported_file": check.get("file_path", ""),
                "message": check.get("check_name", check.get("name", "")),
                "resource": check.get("resource", ""),
                "end_line": (check.get("file_line_range") or [0])[-1],
                "remediation_url": generate_remediation_url("checkov", rule_id),
                "fixable": is_fixable,
                "fixed": is_fixed,
            }
            if line_val and line_val > 0:
                finding["line"] = line_val
            findings.append(finding)

    return findings, False, fix_count


def run_snyk(scan_dir, severity_filter=None):
    """Run Snyk IaC scan and return normalized findings. Optional — skips if not installed/authenticated."""
    findings = []

    # Check if snyk is available
    if not shutil.which("snyk"):
        print("  [INFO] Snyk CLI not installed — skipping (optional)", file=sys.stderr)
        return findings, True

    # Check authentication
    if not os.environ.get("SNYK_TOKEN"):
        rc, _, _ = run_cmd(["snyk", "whoami"], timeout=10)
        if rc != 0:
            print("  [INFO] Snyk not authenticated — skipping (optional)", file=sys.stderr)
            return findings, True

    cmd = [
        "snyk", "iac", "test",
        str(scan_dir),
        "--json",
    ]

    if severity_filter:
        # Map to Snyk's --severity-threshold (lowest severity to include)
        sev_order = ["LOW", "MEDIUM", "HIGH", "CRITICAL"]
        lowest = min(severity_filter, key=lambda s: sev_order.index(s) if s in sev_order else 3)
        cmd.extend(["--severity-threshold", lowest.lower()])

    # .snyk policy file
    snyk_policy = Path(scan_dir) / ".snyk"
    if not snyk_policy.exists():
        snyk_policy = Path.cwd() / ".snyk"
    if snyk_policy.exists():
        cmd.extend(["--policy-path", str(snyk_policy.parent)])

    rc, stdout, stderr = run_cmd(cmd)

    if rc not in (0, 1):
        print(f"  [WARN] Snyk scan failed (exit {rc}): {stderr.strip()[:200]}", file=sys.stderr)
        return findings, True

    try:
        data = validate_report(json.loads(stdout), "snyk")
    except (ValueError, TypeError):
        print("  [WARN] Snyk returned invalid JSON", file=sys.stderr)
        return findings, True

    # Parse Snyk JSON output
    issues = [dict(issue, targetFile=issue.get("targetFile") or doc.get("targetFile", ""))
              for doc in (data if isinstance(data, list) else [data])
              for issue in doc["infrastructureAsCodeIssues"]]
    for issue in issues:
        raw_severity = issue.get("severity", "medium")
        normalized = map_snyk_severity(raw_severity)
        rule_id = issue.get("id") or issue.get("publicId", "")

        line_val = issue.get("lineNumber", 0)
        finding = {
            "rule_id": rule_id,
            "tool": "snyk",
            "severity": normalized,
            "file": scanner_path(issue.get("targetFile") or issue.get("filePath", ""), "snyk", policy_root(scan_dir), scan_dir),
            "reported_file": issue.get("filePath") or issue.get("targetFile", ""),
            "message": issue.get("title", issue.get("iacDescription", {}).get("issue", "")),
            "resource": issue.get("msg", ""),
            "remediation_url": generate_remediation_url("snyk", rule_id),
            "fixable": False,
            "fixed": False,
        }
        if line_val and line_val > 0:
            finding["line"] = line_val
        findings.append(finding)

    return findings, False


def policy_root(scan_dir):
    current = Path(scan_dir).resolve()
    for parent in (current, *current.parents):
        if (parent / "scan-config.yaml").exists() or (parent / ".git").exists():
            return parent
    return current


def load_baseline(scan_dir, allow_legacy=False):
    return baseline_keys(policy_root(scan_dir) / ".scan-baseline/baseline.json", allow_legacy)


def compute_baseline_hash(rule_id, file_path):
    """Legacy identity, used only with explicit migration opt-in."""
    return hashlib.sha256(f"{rule_id}|{file_path}".encode()).hexdigest()


def load_suppressions(scan_dir, allow_legacy=False):
    return load_suppression_entries(suppression_file(policy_root(scan_dir)), allow_legacy)


def filter_by_severity(findings, severity_filter):
    """Filter findings to only include specified severity levels."""
    return [f for f in findings if f.get("severity") in severity_filter]


def format_text_output(findings, auto_fix, fix_count, scan_dir, tools, output_file):
    """Format findings as human-readable text."""
    lines = []

    severity_counts = count_by_severity(findings)
    total = len(findings)

    lines.append(
        f"Findings: {total} ("
        f"{severity_counts['CRITICAL']} CRITICAL, "
        f"{severity_counts['HIGH']} HIGH, "
        f"{severity_counts['MEDIUM']} MEDIUM, "
        f"{severity_counts['LOW']} LOW)"
    )

    # Sort by severity (CRITICAL first), then file
    sorted_findings = sorted(
        findings,
        key=lambda f: (SEVERITY_ORDER.get(f.get("severity", "LOW"), 3), f.get("file", "")),
    )

    for f in sorted_findings:
        sev = f["severity"]
        file_line = f"{f['file']}:{f['line']}" if f.get("line") else f["file"]
        fixed_tag = " [FIXED]" if f.get("fixed") else ""
        lines.append(f"  {sev:8s}: {file_line} - {f['message']} ({f['rule_id']}) [{f['tool']}]{fixed_tag}")

    if auto_fix and fix_count > 0:
        fixed_ids = [f["rule_id"] for f in findings if f.get("fixed")]
        lines.append(f"\nAuto-fix: {fix_count} finding(s) fixed ({', '.join(fixed_ids)})")
        remaining = total - fix_count
        if remaining > 0:
            lines.append(f"Remaining: {remaining} finding(s) require manual remediation")

    lines.append(f"\nResults written to {output_file}")

    return "\n".join(lines)


def build_report(findings, scan_dir, tools_executed, duration_ms, auto_fix, fix_count):
    """Build the agent report conforming to schemas/last-scan.schema.json."""
    severity_counts = count_by_severity(findings)
    tool_counts = count_by_tool(findings)
    fixable_count = sum(1 for f in findings if f.get("fixable"))
    unfixable_count = len(findings) - fixable_count

    report = {
        "schema_version": "1.0",
        "scan_id": str(uuid.uuid4()),
        "scan_timestamp": datetime.now(timezone.utc).isoformat(),
        "duration_ms": duration_ms,
        "scan_directory": str(scan_dir).replace("\\", "/"),
        "tools_executed": tools_executed,
        "auto_fix_applied": auto_fix,
        "auto_fix_count": fix_count,
        "summary": {
            "total_findings": len(findings),
            "by_severity": severity_counts,
            "by_tool": tool_counts,
            "fixable": fixable_count,
            "unfixable": unfixable_count,
        },
        "findings": findings,
    }

    return report


def main():
    parser = argparse.ArgumentParser(
        description="Terraform security scanning interface",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "directory",
        nargs="?",
        default=".",
        help="Directory to scan (default: current directory)",
    )
    parser.add_argument(
        "--format",
        choices=["text", "json"],
        default="text",
        help="Output format (default: text)",
    )
    parser.add_argument(
        "--severity",
        default="CRITICAL,HIGH",
        help="Comma-separated severity filter (default: CRITICAL,HIGH)",
    )
    parser.add_argument(
        "--auto-fix",
        action="store_true",
        help="Apply Checkov --fix for fixable findings",
    )
    parser.add_argument(
        "--output-file",
        default=".scanning/last-scan.json",
        help="JSON output path (default: .scanning/last-scan.json)",
    )
    parser.add_argument(
        "--cloud-provider",
        choices=["aws", "azure", "gcp"],
        default=None,
        help="Cloud provider (default: auto-detect)",
    )
    parser.add_argument(
        "--tools",
        default="trivy,checkov",
        help="Comma-separated tool list (default: trivy,checkov)",
    )
    parser.add_argument(
        "--skip-baseline",
        action="store_true",
        help="Ignore baseline filtering",
    )
    parser.add_argument(
        "--skip-suppressions",
        action="store_true",
        help="Ignore suppression filtering",
    )

    parser.add_argument("--allow-legacy-exceptions", action="store_true",
                        help="Explicit migration opt-in for schema 1.0 exceptions")
    parser.add_argument("--policy-root", default=None,
                        help="Trusted policy checkout (CI supplies the protected base)")
    args = parser.parse_args()

    scan_dir = Path(args.directory).resolve()
    if not scan_dir.is_dir():
        print(f"Error: '{args.directory}' is not a directory", file=sys.stderr)
        sys.exit(2)

    severity_filter = [s.strip().upper() for s in args.severity.split(",")]
    tools_to_run = [t.strip().lower() for t in args.tools.split(",")]
    if not tools_to_run or any(tool not in {"trivy", "checkov", "snyk"} for tool in tools_to_run):
        parser.error("Select one or more supported scanners")

    # Auto-detect cloud provider if not specified
    cloud_provider = args.cloud_provider or detect_cloud_provider(str(scan_dir))

    # Locate Checkov config
    checkov_config = None
    if cloud_provider:
        for candidate in [
            scan_dir / ".scanning" / "configs" / ".checkov.yaml",
            Path.cwd() / ".scanning" / "configs" / ".checkov.yaml",
        ]:
            if candidate.exists():
                checkov_config = str(candidate)
                break

    print(f"Scanning {scan_dir} with {', '.join(tools_to_run)}...")
    if cloud_provider:
        print(f"  Cloud provider: {cloud_provider}")
    print()

    start_time = time.time()
    all_findings = []
    tools_executed = []
    had_error = False
    total_fix_count = 0

    # Run Trivy
    if "trivy" in tools_to_run:
        trivy_findings, trivy_error = run_trivy(scan_dir, severity_filter)
        if trivy_error:
            had_error = True
        else:
            tools_executed.append("trivy")
        all_findings.extend(trivy_findings)

    # Run Checkov
    if "checkov" in tools_to_run:
        checkov_findings, checkov_error, fix_count = run_checkov(
            scan_dir, auto_fix=args.auto_fix, config_file=checkov_config
        )
        if checkov_error:
            had_error = True
        else:
            tools_executed.append("checkov")
        all_findings.extend(checkov_findings)
        total_fix_count += fix_count

    # Run Snyk (optional — skips if not installed or not authenticated)
    if "snyk" in tools_to_run:
        snyk_findings, snyk_error = run_snyk(scan_dir, severity_filter)
        if snyk_error:
            had_error = True
        elif snyk_findings is not None:
            tools_executed.append("snyk")
        all_findings.extend(snyk_findings)

    # Apply severity filter
    filtered_findings = filter_by_severity(all_findings, severity_filter)

    try:
        apply_exceptions(filtered_findings, policy_root(scan_dir),
                         args.policy_root or policy_root(scan_dir),
                         suppressions=not args.skip_suppressions,
                         baseline=not args.skip_baseline,
                         allow_legacy=args.allow_legacy_exceptions)
        filtered_findings = [f for f in filtered_findings if not f["suppressed"] and not f["baseline"]]
    except (OSError, ValueError, TypeError) as exc:
        print(f"Policy validation failed: {exc}", file=sys.stderr)
        had_error = True

    duration_ms = int((time.time() - start_time) * 1000)

    # Build report
    report = build_report(
        filtered_findings, scan_dir, tools_executed, duration_ms,
        args.auto_fix, total_fix_count,
    )

    report["scan_complete"] = not had_error

    # Write output file
    output_path = Path(args.output_file)
    try:
        write_text(output_path, json.dumps(report, indent=2))
    except OSError as e:
        print(f"  [WARN] Could not write output file: {e}", file=sys.stderr)
        had_error = True

    # Display output
    if args.format == "json":
        print(json.dumps(report, indent=2))
    else:
        print(format_text_output(
            filtered_findings, args.auto_fix, total_fix_count,
            scan_dir, tools_executed, args.output_file,
        ))

    # Exit code
    if had_error:
        # Tool error -- signal ambiguity to caller (exit 2 per CLI contract)
        sys.exit(2)
    elif filtered_findings:
        # Remove fixed findings from the "actionable" count
        unfixed = [f for f in filtered_findings if not f.get("fixed")]
        if unfixed:
            sys.exit(1)
        else:
            sys.exit(0)
    else:
        sys.exit(0)


if __name__ == "__main__":
    main()
