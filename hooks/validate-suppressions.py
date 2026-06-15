#!/usr/bin/env python3
"""Pre-commit hook: Validate .scan-suppressions.yaml syntax and structure.

Validates the suppression file against rules V-001 through V-009 from the
suppression-format.md contract. Designed to run as a pre-commit hook (fast,
syntax-only validation) and also usable standalone.

Validation Rules (Errors - block commit):
  V-001: YAML must be syntactically valid
  V-002: schema_version must be present and equal to "1.0"
  V-003: All required fields must be present in each entry
  V-004: tool must be one of the allowed enum values
  V-005: approved_date and expires_date must be valid ISO dates
  V-006: expires_date must be <= max_expiry_days after approved_date
  V-007: approved_by must be present when severity in require_security_approval
  V-008: No duplicate (rule_id, tool) pairs in the same tool section
  V-009: rule_id must match expected pattern for declared tool

Warnings (informational, do not block):
  W-001: Suppression expires within 30 days
  W-002: ticket field is empty
  W-003: severity field is missing

Exit Codes:
  0 - All suppressions valid
  1 - Validation errors found
  2 - Infra error (e.g. missing PyYAML); shell wrapper fails open

Usage:
  python hooks/validate-suppressions.py                        # default file
  python hooks/validate-suppressions.py path/to/file.yaml      # specific file
  python hooks/validate-suppressions.py --strict                # warnings as errors
  python hooks/validate-suppressions.py --check-expiry          # warn on near-expiry
"""

import re
import sys
from datetime import date, datetime, timedelta
from pathlib import Path

try:
    import yaml
except ImportError:
    # Infra problem (missing dependency), not a validation failure. Exit 2 so the
    # shell wrapper treats it as an infra error (fail-open) rather than blocking
    # the commit — consistent with the rest of the system's exit-code contract.
    print("ERROR: PyYAML is required. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(2)

# Required fields per suppression entry
REQUIRED_FIELDS = ["rule_id", "tool", "reason", "owner", "approved_date", "expires_date"]

# Allowed tool values (snyk_suppressions is a declared section, so snyk must be allowed)
ALLOWED_TOOLS = {"trivy", "checkov", "tflint", "gitleaks", "snyk"}

# Allowed severity values
ALLOWED_SEVERITIES = {"CRITICAL", "HIGH", "MEDIUM", "LOW"}

# Rule ID patterns by tool
RULE_ID_PATTERNS = {
    "trivy": re.compile(r"^AVD-[A-Z]+-\d+$"),
    "checkov": re.compile(r"^CKV_[A-Z]+_\d+$"),
    "tflint": re.compile(r"^[a-z][a-z0-9_-]+$"),
    "gitleaks": re.compile(r"^[a-z][a-z0-9-]+$"),
    "snyk": re.compile(r"^SNYK-[A-Z0-9-]+$"),
}

# Tool section names in the YAML file
TOOL_SECTIONS = {
    "trivy": "trivy_suppressions",
    "checkov": "checkov_suppressions",
    "tflint": "tflint_suppressions",
    "gitleaks": "gitleaks_suppressions",
    "snyk": "snyk_suppressions",
}


def parse_iso_date(date_str):
    """Parse an ISO 8601 date string (YYYY-MM-DD) into a pure ``date`` object.

    Rejects ``datetime`` values explicitly: ``datetime`` is a subclass of
    ``date``, and mixing the two in downstream ``date`` arithmetic raises
    ``TypeError``. Only pure ``date`` values (or parseable strings) pass.
    """
    if isinstance(date_str, datetime):
        # YAML may parse a full timestamp into a datetime; reject it so callers
        # don't mix date/datetime in arithmetic. Treat as invalid input.
        return None
    if isinstance(date_str, date):
        return date_str
    try:
        return datetime.strptime(str(date_str), "%Y-%m-%d").date()
    except (ValueError, TypeError):
        return None


def validate_suppressions(file_path, strict=False, check_expiry=False):
    """Validate a suppression file. Returns (errors, warnings)."""
    errors = []
    warnings = []

    # V-001: YAML syntax valid
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
    except yaml.YAMLError as e:
        errors.append(f"V-001: YAML syntax error: {e}")
        return errors, warnings
    except FileNotFoundError:
        errors.append(f"V-001: File not found: {file_path}")
        return errors, warnings
    except OSError as e:
        errors.append(f"V-001: Cannot read file: {e}")
        return errors, warnings

    if data is None:
        errors.append("V-001: File is empty")
        return errors, warnings

    if not isinstance(data, dict):
        errors.append("V-001: File must contain a YAML mapping (not a list or scalar)")
        return errors, warnings

    # V-002: schema_version check
    schema_version = data.get("schema_version")
    if schema_version is None:
        errors.append("V-002: 'schema_version' is required")
    elif str(schema_version) != "1.0":
        errors.append(f"V-002: 'schema_version' must be '1.0', got '{schema_version}'")

    # Extract settings for validation context
    settings = data.get("settings", {})
    if not isinstance(settings, dict):
        settings = {}
    max_expiry_days = settings.get("max_expiry_days", 180)
    # Coerce to int: a YAML string (e.g. max_expiry_days: "180") would otherwise
    # reach timedelta(days=...) and raise TypeError. Reject non-int as a
    # validation error instead of crashing.
    try:
        max_expiry_days = int(max_expiry_days)
    except (TypeError, ValueError):
        errors.append(
            f"V-006: 'settings.max_expiry_days' must be an integer, got '{max_expiry_days}'"
        )
        max_expiry_days = 180
    require_approval = settings.get("require_security_approval", ["CRITICAL", "HIGH"])
    if not isinstance(require_approval, list):
        require_approval = []

    # Validate each tool section
    for tool_name, section_key in TOOL_SECTIONS.items():
        entries = data.get(section_key)
        if entries is None:
            continue
        if not isinstance(entries, list):
            errors.append(f"V-001: '{section_key}' must be a list")
            continue

        seen_rule_ids = set()

        for i, entry in enumerate(entries):
            if not isinstance(entry, dict):
                errors.append(f"V-001: {section_key}[{i}] must be a mapping")
                continue

            prefix = f"{section_key}[{i}]"

            # V-003: Required fields
            for field in REQUIRED_FIELDS:
                if field not in entry or entry[field] is None or str(entry[field]).strip() == "":
                    errors.append(f"V-003: {prefix} missing required field '{field}'")

            # V-004: tool must be valid enum
            entry_tool = entry.get("tool")
            if entry_tool is not None:
                if entry_tool not in ALLOWED_TOOLS:
                    errors.append(f"V-004: {prefix} invalid tool '{entry_tool}' (allowed: {', '.join(sorted(ALLOWED_TOOLS))})")
                elif entry_tool != tool_name:
                    errors.append(f"V-004: {prefix} tool '{entry_tool}' in '{section_key}' section (expected '{tool_name}')")

            # V-005: Date validation
            approved_date = parse_iso_date(entry.get("approved_date"))
            expires_date = parse_iso_date(entry.get("expires_date"))

            if entry.get("approved_date") is not None and approved_date is None:
                errors.append(f"V-005: {prefix} 'approved_date' is not a valid ISO date: '{entry.get('approved_date')}'")
            if entry.get("expires_date") is not None and expires_date is None:
                errors.append(f"V-005: {prefix} 'expires_date' is not a valid ISO date: '{entry.get('expires_date')}'")

            # V-006: expires_date <= max_expiry_days after approved_date
            if approved_date and expires_date:
                max_allowed = approved_date + timedelta(days=max_expiry_days)
                if expires_date > max_allowed:
                    errors.append(
                        f"V-006: {prefix} 'expires_date' ({expires_date}) exceeds "
                        f"max {max_expiry_days} days from 'approved_date' ({approved_date}), "
                        f"max allowed: {max_allowed}"
                    )

            # V-007: approved_by required for high-severity suppressions
            severity = entry.get("severity")
            if severity and severity in require_approval:
                approved_by = entry.get("approved_by")
                if not approved_by or str(approved_by).strip() == "":
                    errors.append(
                        f"V-007: {prefix} 'approved_by' required for {severity} severity "
                        f"(require_security_approval: {require_approval})"
                    )

            # V-008: No duplicate (rule_id, tool) pairs
            rule_id = entry.get("rule_id")
            if rule_id and entry_tool:
                key = (str(rule_id), str(entry_tool))
                if key in seen_rule_ids:
                    errors.append(f"V-008: {prefix} duplicate (rule_id='{rule_id}', tool='{entry_tool}')")
                else:
                    seen_rule_ids.add(key)

            # V-009: rule_id format per tool
            if rule_id and entry_tool and entry_tool in RULE_ID_PATTERNS:
                pattern = RULE_ID_PATTERNS[entry_tool]
                if not pattern.match(str(rule_id)):
                    errors.append(
                        f"V-009: {prefix} rule_id '{rule_id}' does not match expected pattern "
                        f"for {entry_tool} (expected: {pattern.pattern})"
                    )

            # W-001: Expiring soon
            if check_expiry and expires_date:
                days_until_expiry = (expires_date - date.today()).days
                if 0 < days_until_expiry <= 30:
                    warnings.append(f"W-001: {prefix} expires in {days_until_expiry} days ({expires_date})")
                elif days_until_expiry <= 0:
                    warnings.append(f"W-001: {prefix} EXPIRED on {expires_date}")

            # W-002: Missing ticket
            if not entry.get("ticket") or str(entry.get("ticket", "")).strip() == "":
                warnings.append(f"W-002: {prefix} 'ticket' field is empty (recommended)")

            # W-003: Missing severity
            if not severity:
                warnings.append(f"W-003: {prefix} 'severity' field is missing (recommended)")
            elif severity not in ALLOWED_SEVERITIES:
                errors.append(
                    f"V-003: {prefix} invalid severity '{severity}' "
                    f"(allowed: {', '.join(sorted(ALLOWED_SEVERITIES))})"
                )

    # In strict mode, treat warnings as errors
    if strict:
        errors.extend(warnings)
        warnings = []

    return errors, warnings


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Validate .scan-suppressions.yaml")
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

    args = parser.parse_args()

    file_path = Path(args.file)
    if not file_path.exists():
        # In pre-commit context, if the file doesn't exist, nothing to validate
        print(f"No suppression file found at {file_path} - skipping validation")
        sys.exit(0)

    errors, warnings = validate_suppressions(file_path, strict=args.strict, check_expiry=args.check_expiry)

    # Print results
    if warnings:
        for w in warnings:
            print(f"WARNING: {w}")

    if errors:
        for e in errors:
            print(f"ERROR: {e}")
        print(f"\n{len(errors)} validation error(s) found in {file_path}")
        sys.exit(1)

    if warnings:
        print(f"\nValidation passed with {len(warnings)} warning(s)")
    else:
        print(f"Validation passed: {file_path}")

    sys.exit(0)


if __name__ == "__main__":
    main()
