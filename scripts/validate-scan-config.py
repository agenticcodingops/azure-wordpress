#!/usr/bin/env python3
"""validate-scan-config.py — validate scan-config.yaml against schemas/scan-config.schema.json.

Used by both the local hook (hooks/validate-scan-config.{sh,ps1}) and CI. Staged
hook validation and STRICT=1 block missing prerequisites. Direct non-strict use
or the explicit local prerequisite opt-in can skip unavailable dependencies.

Exit codes:
  0 = valid (or deps missing locally and not strict)
  1 = invalid config / config not found in strict mode
"""
from __future__ import annotations

import json
import os
import sys
import subprocess
import tempfile
from pathlib import Path


def _find(start: Path, name: str) -> Path | None:
    for d in [start, *start.parents]:
        p = d / name
        if p.is_file():
            return p
    return None


def main(argv: list[str]) -> int:
    if len(argv) > 1 and argv[1] == '--staged':
        # Package-owned validator and schema, consumer-owned index bytes.
        try:
            root = subprocess.check_output(['git', '--no-replace-objects', 'rev-parse', '--show-toplevel']).decode().strip()
            changed = subprocess.check_output([
                'git', '--no-replace-objects', '-C', root, 'diff', '--cached', '--name-only', '-z',
                '--diff-filter=ACMRTU', '--', 'scan-config.yaml'])
            if b'scan-config.yaml' not in changed.split(b'\0'):
                print('[validate-scan-config] PASS: scan-config.yaml not staged')
                return 0
            entries = subprocess.check_output([
                'git', '--no-replace-objects', '-C', root, 'ls-files', '--stage', '-z', '--', 'scan-config.yaml']).split(b'\0')
            metadata = [entry.split(b'\t', 1)[0].split() for entry in entries if entry]
            if (len(metadata) != 1 or len(metadata[0]) != 3 or
                    metadata[0][0] not in (b'100644', b'100755') or metadata[0][2] != b'0'):
                print('[validate-scan-config] ERROR: staged config must be one regular file')
                return 1
            content = subprocess.check_output(['git', '--no-replace-objects', '-C', root, 'show', ':scan-config.yaml'])
            with tempfile.TemporaryDirectory(prefix='scan-config-') as directory:
                path = Path(directory) / 'scan-config.yaml'
                path.write_bytes(content)
                os.environ['STRICT'] = '0' if os.environ.get('SCAN_ALLOW_TOOL_ERRORS') == '1' else '1'
                return main([argv[0], str(path)])
        except (OSError, subprocess.SubprocessError) as exc:
            print(f'[validate-scan-config] ERROR: cannot read staged config: {exc}')
            return 1
    strict = os.environ.get("STRICT", "0") == "1"
    cfg_path = Path(argv[1]) if len(argv) > 1 else None
    if cfg_path is None:
        found = _find(Path.cwd(), "scan-config.yaml")
        if found is None:
            # In CI (STRICT=1) a missing config must FAIL the gate, not silently pass.
            print("[validate-scan-config] no scan-config.yaml found"
                  + ("; FAILING (strict)" if strict else "; skipping"))
            return 1 if strict else 0
        cfg_path = found

    schema_path = _find(Path(__file__).resolve().parent, "scan-config.schema.json")
    if schema_path is None:
        # Look under schemas/ relative to repo root.
        repo_schema = _find(Path(__file__).resolve().parent.parent / "schemas", "scan-config.schema.json")
        schema_path = repo_schema
    if schema_path is None:
        msg = "schemas/scan-config.schema.json not found"
        print(f"[validate-scan-config] WARNING: {msg}")
        return 1 if strict else 0

    try:
        import yaml  # type: ignore
    except ImportError:
        print("[validate-scan-config] WARNING: PyYAML not installed; skipping (install pyyaml)")
        return 1 if strict else 0

    try:
        import jsonschema  # type: ignore
    except ImportError:
        print("[validate-scan-config] WARNING: jsonschema not installed; skipping (pip install jsonschema)")
        return 1 if strict else 0

    try:
        cfg = yaml.safe_load(cfg_path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        print(f"[validate-scan-config] ERROR: cannot parse {cfg_path}: " + ' '.join(str(exc).splitlines()))
        return 1

    try:
        schema = json.loads(Path(schema_path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"[validate-scan-config] ERROR: cannot read/parse schema {schema_path}: {exc}")
        return 1

    try:
        jsonschema.Draft202012Validator.check_schema(schema)
        validator = jsonschema.Draft202012Validator(schema)
        errors = sorted(validator.iter_errors(cfg), key=lambda e: tuple(str(part) for part in e.path))
    except jsonschema.SchemaError as exc:
        key = '/'.join(str(part) for part in exc.path) or '<root>'
        print(f'[validate-scan-config] ERROR: schema {key}: invalid validation schema')
        return 1
    if errors:
        for err in errors:
            loc = "/".join(str(p) for p in err.path) or "<root>"
            message = ' '.join(err.message.splitlines())
            print(f"[validate-scan-config] INVALID: {loc}: {message}")
        return 1

    print(f"[validate-scan-config] VALID: {cfg_path} conforms to scan-config.schema.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
