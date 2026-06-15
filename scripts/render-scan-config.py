#!/usr/bin/env python3
"""render-scan-config.py — write a consumer scan-config.yaml from a tier template.

Copies templates/scan-config/<tier>.yaml and flips `enabled: true` for the chosen
languages (and fix_loop, if requested), preserving the template's comments. Used by
setup-scan-fix.{ps1,py}. Idempotent: re-running with the same args yields the same file.

Usage:
  render-scan-config.py --tier standard --languages csharp,typescript \
      --templates-dir templates/scan-config --out scan-config.yaml [--enable-fix-loop]
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

KNOWN_LANGUAGES = {"terraform", "csharp", "typescript", "sql"}


def enable_language(text: str, lang: str) -> str:
    # Flip "  <lang>:\n    enabled: false" -> true (enabled is the first key in templates).
    pattern = re.compile(rf"(\n  {re.escape(lang)}:\n    enabled: )false")
    new, n = pattern.subn(r"\1true", text, count=1)
    if n == 0:
        print(f"::warning::language '{lang}' not found in template (skipped)", file=sys.stderr)
    return new


def enable_fix_loop(text: str) -> str:
    return re.sub(r"(\nfix_loop:\n  enabled: )false", r"\1true", text, count=1)


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tier", required=True, choices=["starter", "standard", "strict"])
    ap.add_argument("--languages", default="", help="comma-separated languages to enable")
    ap.add_argument("--templates-dir", default="templates/scan-config")
    ap.add_argument("--out", default="scan-config.yaml")
    ap.add_argument("--enable-fix-loop", action="store_true")
    ap.add_argument("--force", action="store_true", help="overwrite an existing out file")
    args = ap.parse_args(argv[1:])

    template = Path(args.templates_dir) / f"{args.tier}.yaml"
    if not template.is_file():
        print(f"ERROR: template not found: {template}", file=sys.stderr)
        return 1

    out = Path(args.out)
    if out.exists() and not args.force:
        print(f"[render-scan-config] {out} already exists; leaving as-is (use --force to overwrite)")
        return 0

    text = template.read_text(encoding="utf-8")
    langs = [lang_name.strip() for lang_name in args.languages.split(",") if lang_name.strip()]
    for lang in langs:
        if lang not in KNOWN_LANGUAGES:
            print(f"::warning::unknown language '{lang}' (known: {sorted(KNOWN_LANGUAGES)})", file=sys.stderr)
            continue
        text = enable_language(text, lang)
    if args.enable_fix_loop:
        text = enable_fix_loop(text)

    out.write_text(text, encoding="utf-8")
    print(f"[render-scan-config] wrote {out} (tier={args.tier}, languages={langs}, fix_loop={args.enable_fix_loop})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
