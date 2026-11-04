"""Write a schema 2.0 baseline with the same identity used by the gate."""
import argparse
import json
from pathlib import Path
from safe_io import write_text
from scan_policy import checkov_checks, occurrence_fingerprint, scanner_path
from scan_reports import validate_report


def finalize(data, root, policy_root=None, base_commit=None):
    data["schema_version"] = "2.0"
    for report in data.pop("scanner_reports", []):
        validate_report(report["report"], report["tool"])
    # Share the gate's treatment of inline skips and scanner-relative paths.
    for report in data.pop("checkov_reports", []):
        documents = validate_report(report["report"], "checkov")
        if isinstance(documents, dict):
            documents = [documents]
        directory = report["scan_directory"]
        for document in documents:
            summary = document.get("summary") or {}
            count = summary.get("skipped")
            if type(count) is not int or count != len(document["results"].get("skipped_checks", [])):
                raise ValueError("Baseline requires complete Checkov skipped records")
            for check in checkov_checks(document["results"], root, policy_root=policy_root,
                                        scan_directory=directory, base_commit=base_commit):
                lines = check.get("file_line_range") or [0]
                data["entries"].append(dict(
                    rule_id=check["check_id"], file=check["file_path"], tool="checkov",
                    scan_directory=directory, line=lines[0], end_line=lines[-1],
                    resource=check.get("resource", ""), severity=check.get("severity") or "HIGH",
                    baselined_date=report["baselined_date"]))
    # Keep repeated records: each entry authorizes one occurrence only.
    for entry in data["entries"]:
        entry["file"] = scanner_path(entry["file"], entry["tool"], root,
                                     entry.pop("scan_directory", data.get("scan_directory", ".")))
        entry["fingerprint"] = occurrence_fingerprint(entry, root)
        if not entry["fingerprint"]:
            raise ValueError("Baseline entry needs a readable source file and exact location")
        entry.pop("hash", None)
    return data


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("destination")
    parser.add_argument("root")
    trust = parser.add_mutually_exclusive_group()
    trust.add_argument("--policy-root")
    trust.add_argument("--base-commit")
    args = parser.parse_args()
    data = json.loads(Path(args.source).read_text(encoding="utf-8-sig"))
    write_text(args.destination, json.dumps(finalize(data, args.root, args.policy_root, args.base_commit),
                                            indent=2) + "\n")
