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
from safe_io import assert_safe_path, write_text

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


def fix_loop_value(text: str) -> str:
    """Report only a definite YAML boolean; reporting must never block setup."""
    try:
        import yaml
    except ImportError:
        return "unknown"
    try:
        config = yaml.safe_load(text)
        loop = config.get("fix_loop") if isinstance(config, dict) else None
        enabled = loop.get("enabled") if isinstance(loop, dict) else None
    except (yaml.YAMLError, ValueError, RecursionError):
        return "unknown"
    return str(enabled).lower() if isinstance(enabled, bool) else "unknown"


def report_fix_loop(value: str, requested: bool) -> None:
    if value == "true" and not requested:
        print("WARNING: file enables fix_loop without --enable-fix-loop; setup installs the caller, "
              "creates labels and checks secrets only with --enable-fix-loop. "
              "If these are not already configured, run setup with that flag.")
    elif value == "false" and requested:
        print("WARNING: --enable-fix-loop was given but the file still has fix_loop.enabled: false; "
              "review the file or use --force to overwrite it.")


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

    out = assert_safe_path(args.out)
    if out.exists() and not args.force:
        try:
            value = fix_loop_value(out.read_text(encoding="utf-8"))
        except (OSError, UnicodeError):
            value = "unknown"
        print(f"[render-scan-config] {out} already exists; leaving as-is "
              f"(use --force to overwrite; fix_loop={value})")
        report_fix_loop(value, args.enable_fix_loop)
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

    write_text(out, text)
    value = fix_loop_value(text)
    print(f"[render-scan-config] wrote {out} (tier={args.tier}, languages={langs}, fix_loop={value})")
    report_fix_loop(value, args.enable_fix_loop)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
