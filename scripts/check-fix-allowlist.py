#!/usr/bin/env python3
"""check-fix-allowlist.py — enforce the fix_loop path gate (allowlist, not denylist).

The autonomous fix-loop may only touch files that BOTH:
  1. start with one of fix_loop.allowlist_paths (an inclusive allowlist), AND
  2. do NOT contain any fix_loop.gated_paths substring (case-insensitive denylist
     for security-sensitive areas — fail-closed even inside an allowlisted dir).

Used by autonomous-fix.yml (analyze + apply jobs, defense in depth) and by tests.

Inputs:
  - scan-config.yaml resolved from --config or cwd (fix_loop.allowlist_paths / gated_paths)
  - changed files: positional args, or one-per-line on stdin

Exit codes:
  0 = every file is allowed
  1 = at least one file is gated (prints "GATED: <reason>")
  2 = config missing/unreadable (treated as gated → fail closed)
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path


def _load_fix_loop(config_path: Path):
    try:
        import yaml
    except ImportError:
        print("GATED: PyYAML not available to read fix_loop config (fail closed)")
        sys.exit(2)
    if not config_path.is_file():
        print(f"GATED: {config_path} not found (fail closed)")
        sys.exit(2)
    try:
        data = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}
    except Exception as exc:  # malformed/unreadable config -> fail CLOSED, never open
        print(f"GATED: cannot read/parse {config_path}: {exc} (fail closed)")
        sys.exit(2)
    # A malformed top-level (e.g. a YAML list/scalar) is not a dict; .get() would
    # raise AttributeError. Fail CLOSED rather than crash or silently allow.
    if not isinstance(data, dict):
        print(f"GATED: {config_path} top-level is not a mapping (fail closed)")
        sys.exit(2)
    fix_loop = data.get("fix_loop") or {}
    if not isinstance(fix_loop, dict):
        print(f"GATED: {config_path} 'fix_loop' is not a mapping (fail closed)")
        sys.exit(2)
    allow = [str(p) for p in (fix_loop.get("allowlist_paths") or [])]
    gated = [str(p).lower() for p in (fix_loop.get("gated_paths") or [])]
    return allow, gated


def _norm(path: str) -> str:
    p = path.strip().replace("\\", "/")
    while p.startswith("./"):
        p = p[2:]
    return p.rstrip("/")


def _within(file_path: str, allow_path: str) -> bool:
    """True iff file_path is the allow_path itself or a path UNDER it.

    Boundary-aware: enforces a path-segment boundary so a sibling like
    `api/src-malicious/x` does NOT match the allowlist entry `api/src`
    (a bare startswith would have let it through). See PR #145 review.
    """
    a = _norm(allow_path)
    f = _norm(file_path)
    return bool(a) and (f == a or f.startswith(a + "/"))


def check(files, allow, gated):
    """Return (ok: bool, reason: str)."""
    for raw in files:
        f = _norm(raw)
        if not f:
            continue
        if not any(_within(f, a) for a in allow):
            return False, f"non-fixable path (outside allowlist): {f}"
        low = f.lower()
        for g in gated:
            if g and g in low:
                return False, f"security-sensitive path (gated): {f}"
    return True, ""


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*", help="changed files (or pass on stdin, one per line)")
    ap.add_argument("--config", default="scan-config.yaml")
    args = ap.parse_args(argv[1:])

    files = list(args.files)
    if not files and not sys.stdin.isatty():
        files = [line for line in sys.stdin.read().splitlines() if line.strip()]

    allow, gated = _load_fix_loop(Path(args.config))
    if not allow:
        print("GATED: fix_loop.allowlist_paths is empty (fail closed)")
        return 1

    ok, reason = check(files, allow, gated)
    if ok:
        print(f"OK: all {len(files)} changed file(s) within allowlist and clear of gated paths")
        return 0
    print(f"GATED: {reason}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
