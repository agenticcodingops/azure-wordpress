#!/usr/bin/env python3
"""Full suppression validation script for CI and standalone use.

Complete Python rewrite of suppression validation with all rules from
suppression-format.md. Unlike the pre-commit hook version (hooks/validate-suppressions.py),
this version enforces expired suppressions as errors (CI behavior) and provides
richer reporting.

Validation Rules (Errors - block):
  V-001: YAML must be syntactically valid
  V-002: schema_version must be "2.0" (legacy requires explicit opt-in)
  V-003: All required fields must be present in each entry
  V-004: tool must be one of the allowed enum values
  V-005: approved_date and expires_date must be valid ISO dates
  V-006: expires_date must be <= max_expiry_days after approved_date
  V-007: approval always required for HIGH/CRITICAL and configured extra levels
  V-008: No duplicate (rule_id, tool, fingerprint) occurrence keys
  V-009: rule_id must match expected pattern for declared tool
  V-010: Versioned occurrence fingerprint required

Warnings:
  W-001: Suppression expires within 30 days
  W-002: ticket field is empty
  W-003: severity field is missing

Exit Codes:
  0 - All suppressions valid
  1 - Validation errors found

Usage:
  python scripts/validate-suppressions.py                              # default file
  python scripts/validate-suppressions.py path/to/suppressions.yaml    # specific file
  python scripts/validate-suppressions.py --strict                     # warnings as errors
  python scripts/validate-suppressions.py --check-expiry               # warn on near-expiry
  python scripts/validate-suppressions.py --ci                         # CI mode: expired = error
  python scripts/validate-suppressions.py --format json                # JSON output
"""

import argparse
import json
import re
import sys
from datetime import date, datetime, timedelta
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

# Required fields per suppression entry
REQUIRED_FIELDS = ["rule_id", "tool", "reason", "owner", "approved_date", "expires_date", "severity"]

# Minimum reason length
MIN_REASON_LENGTH = 10

# Allowed tool values
ALLOWED_TOOLS = {"trivy", "checkov", "tflint", "gitleaks", "snyk"}

# Allowed severity values
ALLOWED_SEVERITIES = {"CRITICAL", "HIGH", "MEDIUM", "LOW"}

# Rule ID patterns by tool
RULE_ID_PATTERNS = {
    "trivy": re.compile(r"^(?:AVD-[A-Z]+-\d+|[a-z][a-z0-9_-]+)$"),
    "checkov": re.compile(r"^CKV2?_[A-Z0-9]+_\d+$"),
    "snyk": re.compile(r"^SNYK-[A-Z0-9-]+$"),
    "tflint": re.compile(r"^[a-z][a-z0-9_-]+$"),
    "gitleaks": re.compile(r"^[a-z][a-z0-9-]+$"),
}

# Email pattern (basic validation)
EMAIL_PATTERN = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

# Tool section names in the YAML file
TOOL_SECTIONS = {
    "trivy": "trivy_suppressions",
    "checkov": "checkov_suppressions",
    "tflint": "tflint_suppressions",
    "gitleaks": "gitleaks_suppressions",
    "snyk": "snyk_suppressions",
}


def parse_iso_date(date_str):
    """Parse an ISO 8601 date string (YYYY-MM-DD) into a date object."""
    if isinstance(date_str, datetime):
        return None
    if isinstance(date_str, date):
        return date_str
    try:
        return datetime.strptime(str(date_str), "%Y-%m-%d").date()
    except (ValueError, TypeError):
        return None


class ValidationResult:
    """Collects validation errors and warnings."""

    def __init__(self):
        self.errors = []
        self.warnings = []
        self.entry_count = 0
        self.section_counts = {}

    def error(self, rule, message):
        self.errors.append({"rule": rule, "message": message})

    def warning(self, rule, message):
        self.warnings.append({"rule": rule, "message": message})

    @property
    def has_errors(self):
        return len(self.errors) > 0

    def to_dict(self):
        return {
            "valid": not self.has_errors,
            "entry_count": self.entry_count,
            "section_counts": self.section_counts,
            "error_count": len(self.errors),
            "warning_count": len(self.warnings),
            "errors": self.errors,
            "warnings": self.warnings,
        }


def validate_entry(entry, index, section_key, tool_name, settings, result, ci_mode=False, check_expiry=False, warning_days=30):
    """Validate a single suppression entry."""
    if not isinstance(entry, dict):
        result.error("V-001", f"{section_key}[{index}] must be a mapping")
        return

    prefix = f"{section_key}[{index}]"
    max_expiry_days = settings.get("max_expiry_days", 180)
    require_approval = settings.get("require_security_approval", [])
    if not isinstance(require_approval, list):
        result.error("V-007", "require_security_approval must be a list")
        require_approval = []
    require_approval = {"CRITICAL", "HIGH"}.union(str(s) for s in require_approval)

    # V-003: Required fields
    for field in REQUIRED_FIELDS:
        value = entry.get(field)
        if value is None or str(value).strip() == "":
            result.error("V-003", f"{prefix} missing required field '{field}'")

    # V-003: Reason length check
    reason = entry.get("reason", "")
    if reason and len(str(reason).strip()) < MIN_REASON_LENGTH:
        result.error("V-003", f"{prefix} 'reason' must be at least {MIN_REASON_LENGTH} characters")

    # V-004: tool must be valid enum
    entry_tool = entry.get("tool")
    if entry_tool is not None:
        if entry_tool not in ALLOWED_TOOLS:
            result.error("V-004", f"{prefix} invalid tool '{entry_tool}' (allowed: {', '.join(sorted(ALLOWED_TOOLS))})")
        elif entry_tool != tool_name:
            result.error("V-004", f"{prefix} tool '{entry_tool}' in '{section_key}' section (expected '{tool_name}')")

    # V-005: Date validation
    approved_date = parse_iso_date(entry.get("approved_date"))
    expires_date = parse_iso_date(entry.get("expires_date"))

    if entry.get("approved_date") is not None and approved_date is None:
        result.error("V-005", f"{prefix} 'approved_date' is not a valid ISO date: '{entry.get('approved_date')}'")
    if entry.get("expires_date") is not None and expires_date is None:
        result.error("V-005", f"{prefix} 'expires_date' is not a valid ISO date: '{entry.get('expires_date')}'")

    # V-006: expires_date <= max_expiry_days after approved_date
    if approved_date and expires_date:
        if approved_date > date.today() or expires_date < approved_date:
            result.error("V-005", f"{prefix} invalid approval date range")
        max_allowed = approved_date + timedelta(days=max_expiry_days)
        if expires_date > max_allowed:
            result.error(
                "V-006",
                f"{prefix} 'expires_date' ({expires_date}) exceeds "
                f"max {max_expiry_days} days from 'approved_date' ({approved_date}), "
                f"max allowed: {max_allowed}",
            )

    # V-007: approved_by required for high-severity suppressions
    severity = entry.get("severity")
    if severity and severity in require_approval:
        approved_by = entry.get("approved_by")
        if not approved_by or str(approved_by).strip() == "":
            result.error(
                "V-007",
                f"{prefix} 'approved_by' required for {severity} severity "
                f"(require_security_approval: {require_approval})",
            )

    # V-009: rule_id format per tool
    rule_id = entry.get("rule_id")
    if rule_id and entry_tool and entry_tool in RULE_ID_PATTERNS:
        pattern = RULE_ID_PATTERNS[entry_tool]
        if not pattern.match(str(rule_id)):
            result.error(
                "V-009",
                f"{prefix} rule_id '{rule_id}' does not match expected pattern "
                f"for {entry_tool} (expected: {pattern.pattern})",
            )

    # Owner email validation (soft check)
    owner = entry.get("owner")
    if owner and not EMAIL_PATTERN.match(str(owner)):
        result.warning("W-004", f"{prefix} 'owner' does not look like an email address: '{owner}'")

    # Expiry checks
    if check_expiry and expires_date:
        days_until_expiry = (expires_date - date.today()).days
        if days_until_expiry < 0:
            if ci_mode:
                result.error("V-006", f"{prefix} EXPIRED on {expires_date} ({abs(days_until_expiry)} days ago)")
            else:
                result.warning("W-001", f"{prefix} EXPIRED on {expires_date} ({abs(days_until_expiry)} days ago)")
        elif days_until_expiry <= warning_days:
            result.warning("W-001", f"{prefix} expires in {days_until_expiry} days ({expires_date})")

    # W-002: Missing ticket
    if not entry.get("ticket") or str(entry.get("ticket", "")).strip() == "":
        result.warning("W-002", f"{prefix} 'ticket' field is empty (recommended)")

    # W-003: Missing severity
    if not severity:
        result.warning("W-003", f"{prefix} 'severity' field is missing (recommended)")
    elif severity not in ALLOWED_SEVERITIES:
        result.error(
            "V-003",
            f"{prefix} invalid severity '{severity}' "
            f"(allowed: {', '.join(sorted(ALLOWED_SEVERITIES))})",
        )


def validate_file(file_path, strict=False, check_expiry=False, ci_mode=False, allow_legacy=False, warning_days=30):
    """Validate a suppression file. Returns a ValidationResult."""
    # CI mode implies check_expiry
    if ci_mode:
        check_expiry = True
    result = ValidationResult()

    # V-001: YAML syntax valid
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
    except yaml.YAMLError as e:
        result.error("V-001", f"YAML syntax error: {e}")
        return result
    except FileNotFoundError:
        result.error("V-001", f"File not found: {file_path}")
        return result
    except OSError as e:
        result.error("V-001", f"Cannot read file: {e}")
        return result

    if data is None:
        result.error("V-001", "File is empty")
        return result

    if not isinstance(data, dict):
        result.error("V-001", "File must contain a YAML mapping (not a list or scalar)")
        return result

    # V-002: schema_version check
    schema_version = data.get("schema_version")
    if schema_version is None:
        result.error("V-002", "'schema_version' is required")
    elif str(schema_version) != "2.0" and not (allow_legacy and str(schema_version) == "1.0"):
        result.error("V-002", f"'schema_version' must be '2.0', got '{schema_version}'")

    # Extract settings
    settings = data.get("settings", {})
    if not isinstance(settings, dict):
        result.error("V-001", "settings must be a mapping")
        settings = {}
    settings = dict(settings)
    maximum = settings.get("max_expiry_days", 180)
    try:
        if isinstance(maximum, (bool, float)):
            raise ValueError()
        maximum = int(maximum)
        if maximum < 1 or maximum > 180:
            raise ValueError()
    except (ValueError, TypeError):
        result.error("V-006", "max_expiry_days must be an integer between 1 and 180")
        maximum = 180
    settings["max_expiry_days"] = maximum

    # Validate required settings fields
    for field in ["max_expiry_days", "require_security_approval", "review_frequency_days"]:
        if field not in settings:
            result.warning("W-004", f"'settings.{field}' is recommended")

    # Validate each tool section
    for tool_name, section_key in TOOL_SECTIONS.items():
        entries = data.get(section_key)
        if entries is None:
            continue
        if not isinstance(entries, list):
            result.error("V-001", f"'{section_key}' must be a list")
            continue

        result.section_counts[section_key] = len(entries)
        seen_rule_ids = set()

        for i, entry in enumerate(entries):
            result.entry_count += 1

            validate_entry(entry, i, section_key, tool_name, settings, result, ci_mode=ci_mode, check_expiry=check_expiry, warning_days=warning_days)

            # V-008: No duplicate (rule_id, tool) pairs
            if isinstance(entry, dict):
                fingerprint = entry.get("fingerprint")
                if not (allow_legacy and str(schema_version) == "1.0"):
                    if not isinstance(fingerprint, str) or not re.fullmatch(r"v1:[0-9a-f]{64}", fingerprint):
                        result.error("V-010", f"{section_key}[{i}] requires a v1 occurrence fingerprint")
                if entry.get("file_pattern") is not None and not isinstance(entry["file_pattern"], str):
                    result.error("V-003", "file_pattern must be a string")
                rule_id = entry.get("rule_id")
                entry_tool = entry.get("tool")
                if rule_id and entry_tool:
                    key = (str(rule_id), str(entry_tool), str(fingerprint))
                    if key in seen_rule_ids:
                        result.error("V-008", f"{section_key}[{i}] duplicate (rule_id='{rule_id}', tool='{entry_tool}')")
                    else:
                        seen_rule_ids.add(key)

    # Strict mode: promote warnings to errors
    if strict:
        result.errors.extend(result.warnings)
        result.warnings = []

    return result


def format_text(result, file_path):
    """Format validation result as human-readable text."""
    lines = []

    if result.warnings:
        for w in result.warnings:
            lines.append(f"WARNING [{w['rule']}]: {w['message']}")

    if result.errors:
        for e in result.errors:
            lines.append(f"ERROR [{e['rule']}]: {e['message']}")

    lines.append("")

    if result.has_errors:
        lines.append(f"{len(result.errors)} validation error(s) found in {file_path}")
    elif result.warnings:
        lines.append(f"Validation passed with {len(result.warnings)} warning(s) ({result.entry_count} entries in {file_path})")
    else:
        lines.append(f"Validation passed: {file_path} ({result.entry_count} entries)")

    return "\n".join(lines)


def format_json(result, file_path):
    """Format validation result as JSON."""
    output = result.to_dict()
    output["file"] = str(file_path)
    return json.dumps(output, indent=2)


def main():
    parser = argparse.ArgumentParser(
        description="Validate .scan-suppressions.yaml (full validation)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "file",
        nargs="?",
        default=".scan-suppressions.yaml",
        help="Suppression file path (default: .scan-suppressions.yaml)",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Treat warnings as errors",
    )
    parser.add_argument(
        "--check-expiry",
        action="store_true",
        help="Warn on suppressions expiring within 30 days",
    )
    parser.add_argument(
        "--ci",
        action="store_true",
        help="CI mode: treat expired suppressions as errors",
    )
    parser.add_argument(
        "--format",
        choices=["text", "json"],
        default="text",
        help="Output format (default: text)",
    )

    parser.add_argument("--allow-legacy-exceptions", action="store_true",
                        help="Explicitly accept schema 1.0 exceptions during migration")
    parser.add_argument("--warning-days", type=int, default=30, help="Upcoming-expiry warning window")
    args = parser.parse_args()
    if args.warning_days < 1:
        parser.error("--warning-days must be positive")

    file_path = Path(args.file)
    if not file_path.exists():
        if args.format == "json":
            print(json.dumps({"valid": True, "file": str(file_path), "message": "No suppression file found"}))
        else:
            print(f"No suppression file found at {file_path} - skipping validation")
        sys.exit(0)

    # CI mode implies check-expiry
    check_expiry = args.check_expiry or args.ci

    result = validate_file(file_path, strict=args.strict, check_expiry=check_expiry, ci_mode=args.ci,
                           allow_legacy=args.allow_legacy_exceptions, warning_days=args.warning_days)

    if args.format == "json":
        print(format_json(result, file_path))
    else:
        print(format_text(result, file_path))

    sys.exit(1 if result.has_errors else 0)


if __name__ == "__main__":
    main()
