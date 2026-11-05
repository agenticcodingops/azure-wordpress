#!/usr/bin/env python3
"""Restrict commit-stage Trivy findings to the immutable selection manifest."""
import json
import os
from pathlib import Path
import sys


def filter_report(report, directory, manifest):
    if not isinstance(report, dict) or not isinstance(report.get('Results'), list):
        raise ValueError('Missing Trivy Results array')
    selected = {os.fsdecode(name) for name in manifest.read_bytes().split(b'\0') if name}
    root = Path.cwd().resolve()
    module = (root / directory).resolve()
    results = []
    observed_findings = False
    for result in report['Results']:
        if not isinstance(result, dict):
            raise ValueError('Invalid Trivy result')
        findings = result.get('Misconfigurations', [])
        if not isinstance(findings, list):
            raise ValueError('Invalid Trivy misconfigurations')
        if not findings:
            continue
        if any(not isinstance(finding, dict) or finding.get('Severity') not in
               ('CRITICAL', 'HIGH', 'MEDIUM', 'LOW', 'UNKNOWN') for finding in findings):
            raise ValueError('Invalid Trivy finding')
        observed_findings = True
        target = result.get('Target')
        if not isinstance(target, str) or not target:
            raise ValueError('Missing Trivy target')
        target = Path(target)
        context = module.relative_to(root)
        if target.is_absolute():
            candidate = target
        elif context.parts and target.parts[:len(context.parts)] == context.parts:
            candidate = root / target
            if candidate.is_file() and (module / target).is_file():
                raise ValueError('Ambiguous Trivy directory prefix')
        else:
            candidate = module / target
        path = candidate.resolve().relative_to(root).as_posix()
        if not candidate.is_file():
            raise ValueError('Trivy target does not name a snapshot file')
        if path in selected:
            results.append(result)
    # This helper handles exit 1 only. No findings at all cannot justify turning
    # that status into success; a missing/broken report must remain fail-closed.
    if not observed_findings:
        raise ValueError('Trivy returned findings status without findings')
    report['Results'] = results
    return report


if __name__ == '__main__':
    try:
        report = filter_report(json.load(sys.stdin.buffer), sys.argv[1], Path(sys.argv[2]))
        print(json.dumps(report))
        raise SystemExit(1 if report['Results'] else 0)
    except (OSError, ValueError, IndexError) as exc:
        print(f'[trivy] ERROR: Cannot select commit findings: {exc}; scan incomplete', file=sys.stderr)
        raise SystemExit(2)
