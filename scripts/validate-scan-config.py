#!/usr/bin/env python3
"""validate-scan-config.py — validate scan-config.yaml against schemas/scan-config.schema.json.

Used by both the local hook (hooks/validate-scan-config.{sh,ps1}) and CI. Designed to
fail-open (exit 0 with a warning) when optional deps are missing locally, but to fail-closed
(exit 1) in CI where STRICT=1 is set, so a malformed consumer config never ships silently.

Exit codes:
  0 = valid (or deps missing locally and not strict)
  1 = invalid config / config not found in strict mode
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def _find(start: Path, name: str) -> Path | None:
    for d in [start, *start.parents]:
        p = d / name
        if p.is_file():
            return p
    return None


def main(argv: list[str]) -> int:
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
        print(f"[validate-scan-config] ERROR: cannot parse {cfg_path}: {exc}")
        return 1

    schema = json.loads(Path(schema_path).read_text(encoding="utf-8"))

    validator = jsonschema.Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(cfg), key=lambda e: list(e.path))
    if errors:
        print(f"[validate-scan-config] INVALID: {cfg_path}")
        for err in errors:
            loc = "/".join(str(p) for p in err.path) or "<root>"
            print(f"  - {loc}: {err.message}")
        return 1

    print(f"[validate-scan-config] VALID: {cfg_path} conforms to scan-config.schema.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
