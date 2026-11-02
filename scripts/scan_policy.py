"""Shared occurrence identity and exception matching for local scans and CI.

Policy directories are supplied separately from the source tree. CI must supply
the protected base checkout; local scans use the repository containing the input.
"""
from collections import Counter
import fnmatch
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re

FINGERPRINT = re.compile(r"^v1:[0-9a-f]{64}$")


def scanner_path(raw, tool, source_root=".", scan_directory="."):
    """Convert scanner-specific paths to a repository-relative path."""
    root = Path(source_root).resolve()
    value = str(raw)
    if os.name == "nt":
        value = value.replace("\\", "/")
    if value.startswith("/github/workspace/"):
        value = value[len("/github/workspace/"):]
    context = (root / scan_directory).resolve()
    candidate = root / value
    if tool == "checkov" and value.startswith("/") and not candidate.is_file():
        candidate = context / value.lstrip("/")
    elif not Path(value).is_absolute():
        context_relative = context.relative_to(root).as_posix()
        if context_relative != "." and not value.startswith(context_relative + "/"):
            candidate = context / value
    try:
        return candidate.resolve().relative_to(root).as_posix()
    except ValueError:
        return value


def source_path(finding, root):
    root = Path(root).resolve()
    value = str(finding.get("file", finding.get("file_path", "")))
    if os.name == "nt":
        value = value.replace("\\", "/")
    path = Path(value)
    # Checkov's file_path uses a leading slash for paths relative to its scan root.
    if finding.get("tool") == "checkov" and value.startswith("/") and not path.is_file():
        path = Path(value.lstrip("/"))
    path = (root / path).resolve()
    relative = path.relative_to(root).as_posix()
    return path, relative


def occurrence_fingerprint(finding, root="."):
    """Bind identity to tool, rule, repository path, resource, range and file bytes.

    A missing source file or location cannot authorize an exact exception.
    Entire-file content identity deliberately invalidates approval after edits.
    CRLF and LF checkouts share the same identity.
    """
    try:
        path, relative = source_path(finding, root)
        line = int(finding.get("line", 0))
        if line < 1 or not finding.get("rule_id") or not finding.get("tool"):
            return None
        content = path.read_bytes().replace(b"\r\n", b"\n")
        identity = dict(tool=finding["tool"], rule_id=finding["rule_id"],
                        file=relative, resource=str(finding.get("resource") or ""),
                        line=line, end_line=int(finding.get("end_line") or line),
                        content_sha256=hashlib.sha256(content).hexdigest())
        encoded = json.dumps(identity, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
        return "v1:" + hashlib.sha256(encoded.encode("utf-8")).hexdigest()
    except (OSError, ValueError, TypeError):
        return None


def suppression_file(policy_root):
    """Resolve the same configured registry for CI, hooks and scan.py."""
    import yaml
    root = Path(policy_root).resolve()
    config = root / "scan-config.yaml"
    name = ".scan-suppressions.yaml"
    if config.exists():
        data = yaml.safe_load(config.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError("scan-config.yaml must be a mapping")
        name = (data.get("suppressions") or {}).get("file", name)
    candidate = (root / name).resolve()
    candidate.relative_to(root)  # policy cannot name files outside its checkout
    return candidate


def load_suppression_entries(path, allow_legacy=False):
    import yaml
    path = Path(path)
    if not path.exists():
        return []
    spec = importlib.util.spec_from_file_location("_suppression_validator", Path(__file__).with_name("validate-suppressions.py"))
    validator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(validator)
    result = validator.validate_file(path, ci_mode=True, allow_legacy=allow_legacy)
    if result.has_errors:
        raise ValueError("Invalid suppression registry: " + "; ".join(e["message"] for e in result.errors))
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    return [entry for section in validator.TOOL_SECTIONS.values() for entry in (data.get(section) or [])]


def baseline_keys(path, allow_legacy=False):
    path = Path(path)
    if not path.exists():
        return Counter()
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or not isinstance(data.get("entries"), list):
        raise ValueError("Invalid baseline report")
    legacy = str(data.get("schema_version")) == "1.0"
    if str(data.get("schema_version")) != "2.0" and not (allow_legacy and legacy):
        raise ValueError("Baseline schema 2.0 required; regenerate the baseline")
    keys = Counter()
    for entry in data["entries"]:
        key = entry.get("hash") if legacy else entry.get("fingerprint")
        if not isinstance(key, str) or (not legacy and not FINGERPRINT.fullmatch(key)):
            raise ValueError("Invalid baseline occurrence fingerprint")
        keys[key] += 1
    return keys


def apply_exceptions(findings, source_root, policy_root, suppressions=True, baseline=True, allow_legacy=False):
    """Consume each approved occurrence once, retaining all finding records."""
    entries = load_suppression_entries(suppression_file(policy_root), allow_legacy) if suppressions else []
    remaining = list(entries)
    keys = baseline_keys(Path(policy_root) / ".scan-baseline/baseline.json", allow_legacy) if baseline else Counter()
    for finding in findings:
        fingerprint = occurrence_fingerprint(finding, source_root)
        finding["fingerprint"] = fingerprint
        finding["suppressed"] = finding["baseline"] = False
        for entry in remaining:
            if entry["rule_id"] != finding["rule_id"] or entry["tool"] != finding["tool"]:
                continue
            # Approval must cover the actual severity as well as the declared severity.
            if finding.get("severity") in ("HIGH", "CRITICAL") and not str(entry.get("approved_by") or "").strip():
                continue
            if entry.get("file_pattern"):
                try:
                    _, relative = source_path(finding, source_root)
                except (ValueError, OSError):
                    continue
                if not fnmatch.fnmatchcase(relative, entry["file_pattern"]):
                    continue
            if (fingerprint and entry.get("fingerprint") == fingerprint) or (allow_legacy and not entry.get("fingerprint")):
                finding["suppressed"] = True
                finding["suppression_reason"] = entry["reason"]
                remaining.remove(entry)
                break
        key = fingerprint
        if allow_legacy and not keys[key]:
            for reported_path in (finding.get("reported_file"), finding["file"]):
                if reported_path is None:
                    continue
                candidate = hashlib.sha256(f"{finding['rule_id']}|{reported_path}".encode()).hexdigest()
                if keys[candidate] > 0:
                    key = candidate
                    break
        if keys[key] > 0:
            finding["baseline"] = True
            keys[key] -= 1


if __name__ == "__main__":
    # Used by both shell wrappers to resolve suppressions.file without fallback
    # on parser/dependency errors.
    print(suppression_file(Path.cwd()))
