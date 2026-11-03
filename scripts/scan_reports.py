"""Fail closed on missing, malformed or error-bearing scanner reports."""
import json
from pathlib import Path


def object_list(value, label):
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise ValueError(f"{label} must be an array of objects")
    return value


def validate_report(data, tool):
    documents = data if tool in ("checkov", "snyk") and isinstance(data, list) else [data]
    if not documents:
        raise ValueError(f"{tool} report is empty")
    for doc in documents:
        if not isinstance(doc, dict):
            raise ValueError(f"{tool} report must be an object")
        if doc.get("errors") or doc.get("error") or doc.get("errorCode") or (tool != "snyk" and doc.get("ok") is False):
            raise ValueError(f"{tool} reported errors")
        if tool == "trivy":
            # Trivy legitimately omits Results when no supported input exists.
            if "Results" not in doc and not isinstance(doc.get("SchemaVersion"), int):
                raise ValueError("Trivy report has no schema or results")
            for result in object_list(doc.get("Results", []), "Results"):
                if not isinstance(result.get("Target"), str):
                    raise ValueError("Trivy target missing")
                for key, rule in (("Misconfigurations", "ID"), ("Secrets", "RuleID")):
                    for finding in object_list(result.get(key, []), key):
                        identifier = finding.get(rule) or finding.get("AVDID")
                        if not isinstance(identifier, str) or not identifier or finding.get("Severity") not in ("CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"):
                            raise ValueError("Invalid Trivy finding")
        elif tool == "checkov":
            results = doc.get("results")
            if results is None and all(type(doc.get(key)) is int and doc[key] == 0
                                       for key in ("passed", "failed", "skipped", "parsing_errors", "resource_count")) and isinstance(doc.get("checkov_version"), str):
                # With no supported inputs Checkov emits its summary directly.
                summary = dict(doc)
                doc.clear()
                doc.update(summary=summary, results={"failed_checks": [], "skipped_checks": []})
                results = doc["results"]
            if not isinstance(results, dict) or "failed_checks" not in results:
                raise ValueError("Checkov failed_checks missing")
            if results.get("parsing_errors") or (doc.get("summary") or {}).get("parsing_errors", 0):
                raise ValueError("Checkov parsing errors")
            for key in ("failed_checks", "skipped_checks"):
                for finding in object_list(results.get(key, []), key):
                    if not all(isinstance(finding.get(field), str) and finding[field] for field in ("check_id", "file_path")):
                        raise ValueError("Invalid Checkov finding")
                    lines = finding.get("file_line_range")
                    if lines is not None and (not isinstance(lines, list) or any(type(line) is not int or line < 0 for line in lines)):
                        raise ValueError("Invalid Checkov location")
        elif tool == "tflint":
            for finding in object_list(doc.get("issues"), "issues"):
                if not isinstance(finding.get("rule"), dict) or not isinstance(finding["rule"].get("name"), str) or not finding["rule"]["name"] or not isinstance(finding.get("range"), dict) or not isinstance(finding["range"].get("filename"), str):
                    raise ValueError("Invalid TFLint finding")
        elif tool == "snyk":
            for issue in object_list(doc.get("infrastructureAsCodeIssues"), "infrastructureAsCodeIssues"):
                if not (issue.get("id") or issue.get("publicId")) or issue.get("severity") not in ("critical", "high", "medium", "low") or not (issue.get("targetFile") or doc.get("targetFile")):
                    raise ValueError("Invalid optional scanner finding")
    return data


def load_report(path, tool):
    return validate_report(json.loads(Path(path).read_text(encoding="utf-8")), tool)
