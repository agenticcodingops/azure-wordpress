#!/usr/bin/env python3
"""Check the ``path:line`` anchors and the relative links in the versioned docs pages.

Usage::

    python -I scripts/check-doc-anchors.py [--links] [PAGE ...]

Without arguments the five versioned pages under ``docs/`` are checked. For every
``path:line`` or ``path:line-line`` reference (a bare ``:line`` token inherits the last path
named in the same paragraph) the script reads the cited line(s) in the working tree and
reports whether they contain at least one identifier that the citing paragraph names; for a
``Sources:`` paragraph the identifiers of the whole section count. A miss means the anchor
should be re-read: the line numbers may have moved since the page was anchored.

A cited path that does not exist in the repository is a miss. The one exception is a bare
file name (no ``/``) that is not in the repository root, which the pages use for plugin and
provider source files; those are printed as ``skip`` and not counted.

An anchor that is correct but cites a line in prose only (no shared identifier) can be
recorded in ``scripts/check-doc-anchors.allow``, one entry per line in the form the miss
report prints, ``docs/page.md:<paragraph line> path:line[-line]``, with a short reason after
``#``. A listed anchor reports ``ok (allowed)``. An entry whose anchor no longer exists on
that paragraph is reported as stale and fails the run, so the list cannot rot.

With ``--links`` every relative Markdown link in the pages is also resolved against the
working tree, and a ``#fragment`` is checked against the target file's headings using
GitHub's slug rules.

Exit status is 1 when any unlisted miss, stale allow entry or broken link is found.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALLOW_FILE = Path(__file__).resolve().with_suffix(".allow")
DEFAULT_PAGES = [
    "docs/architecture.md",
    "docs/cost.md",
    "docs/deployment-guide.md",
    "docs/getting-started.md",
    "docs/security-model.md",
]

# `path:12`, `path:12-34` or the shorthand `:12` / `:12-34` inside backticks.
REF_RE = re.compile(r"`([^`\s:]*):(\d+)(?:-(\d+))?`")
IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]{2,}")
LINK_RE = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)\)")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
STOP = {
    "the", "and", "for", "with", "var", "local", "each", "value", "main", "modules", "module",
    "resource", "data", "type", "string", "bool", "number", "list", "map", "object",
    "optional", "default", "true", "false", "null", "name", "site", "wordpress", "azurerm",
    "tags", "count", "key", "id",
}


def paragraphs(lines: list[str]):
    """Yield (start_index, end_index, text) for each blank-line separated block."""
    start = None
    for i, line in enumerate(lines + [""]):
        if line.strip() == "":
            if start is not None:
                yield start, i, "\n".join(lines[start:i])
                start = None
        elif start is None:
            start = i


PROSE_STOP = STOP | {
    "that", "this", "with", "from", "when", "which", "only", "also", "into", "then", "than", "them",
    "they", "their", "there", "these", "those", "what", "where", "whether", "every", "each", "both",
    "same", "other", "because", "before", "after", "while", "unless", "until", "about", "above",
    "below", "under", "over", "between", "through", "without", "within", "does", "not", "are", "was",
    "were", "been", "being", "have", "has", "had", "will", "would", "should", "could", "must", "can",
    "set", "sets", "see", "its", "one", "two", "three", "four", "five", "all", "any", "some", "more",
    "most", "less", "much", "many", "very", "here", "page", "line", "lines", "file", "files", "code",
    "read", "run", "runs", "uses", "used", "using", "creates", "created", "create", "section", "step",
    "steps", "note", "notes", "source", "sources", "microsoft", "azure", "terraform", "provider",
    "resources", "variables", "module", "modules", "block", "blocks", "input", "inputs", "output",
    "outputs", "defaults", "enabled", "disabled", "config", "configuration", "settings", "setting",
    "example", "examples", "resource", "variable", "local", "locals", "description", "count",
    "comment", "keep", "keeps", "still", "always", "never", "already", "make", "makes", "need",
    "needs", "cannot", "yes", "off", "on", "do", "does", "it", "is", "to", "of", "or", "in", "an",
}


def identifiers(text: str) -> tuple[set[str], set[str]]:
    """Return (code identifiers named in backticks, prose words) of a paragraph."""
    found = set()
    for span in re.findall(r"`([^`]*)`", text):
        if REF_RE.fullmatch(f"`{span}`"):
            continue
        for tok in IDENT_RE.findall(span):
            if tok.lower() not in STOP:
                found.add(tok)
    # Bare identifiers with an underscore or a dot are usually code names too.
    for tok in re.findall(r"\b[A-Za-z][A-Za-z0-9]*(?:[_.][A-Za-z0-9]+)+\b", text):
        if tok.lower() not in STOP and not tok.endswith((".md", ".tf")):
            found.add(tok)
    prose = {
        w.lower()
        for w in re.findall(r"[A-Za-z][A-Za-z0-9]{3,}", re.sub(r"`[^`]*`|\]\([^)]*\)", " ", text))
        if w.lower() not in PROSE_STOP
    }
    return found, prose


def fragments(cited: str) -> set[str]:
    """Identifiers on the cited lines, plus the words they are made of, lower-cased."""
    out = set()
    for tok in re.findall(r"[A-Za-z][A-Za-z0-9]*(?:[_.-][A-Za-z0-9]+)*", cited):
        out.add(tok.lower())
        out |= {p.lower() for p in re.split(r"[_.-]", tok) if len(p) >= 3}
    return out


def prose_hit(prose: set[str], frags: set[str]) -> str | None:
    for w in sorted(prose):
        for f in frags:
            if f in PROSE_STOP:
                continue
            if w == f or (len(f) >= 4 and w.startswith(f)) or (len(w) >= 4 and f.startswith(w)):
                return f"{w}~{f}"
    return None


def section_identifiers(lines: list[str], upto: int) -> tuple[set[str], set[str]]:
    start = 0
    for i in range(upto, -1, -1):
        if lines[i].startswith("#"):
            start = i
            break
    return identifiers("\n".join(lines[start:upto]))


def page_key(page: Path) -> str:
    try:
        return page.relative_to(ROOT).as_posix()
    except ValueError:
        return page.as_posix()


def load_allow() -> tuple[dict[tuple[str, int, str], str], list[str]]:
    """Read the allow-list: {(page, paragraph line, cite): reason}, plus malformed lines."""
    allow: dict[tuple[str, int, str], str] = {}
    bad: list[str] = []
    if not ALLOW_FILE.is_file():
        return allow, bad
    for n, raw in enumerate(ALLOW_FILE.read_text(encoding="utf-8").splitlines(), 1):
        entry, _, reason = raw.partition("#")
        parts = entry.split()
        if not parts:
            continue
        where, _, line_no = parts[0].rpartition(":")
        if len(parts) != 2 or not line_no.isdigit() or not where:
            bad.append(f"{ALLOW_FILE.name}:{n}: cannot parse {raw.strip()!r}")
            continue
        allow[(where, int(line_no), parts[1])] = reason.strip()
    return allow, bad


def check_anchors(
    page: Path,
    files: dict[str, list[str] | None],
    allow: dict[tuple[str, int, str], str],
    seen: set[tuple[str, int, str]],
) -> list[str]:
    misses: list[str] = []
    lines = page.read_text(encoding="utf-8").splitlines()
    key = page_key(page)
    total = 0
    for p_start, p_end, text in paragraphs(lines):
        is_sources = text.lstrip().lower().startswith("sources:")
        idents, prose = identifiers(text)
        if is_sources:
            s_idents, s_prose = section_identifiers(lines, p_start)
            idents |= s_idents
            prose |= s_prose
        current = None
        for m in REF_RE.finditer(text):
            path, a, b = m.group(1), int(m.group(2)), int(m.group(3) or m.group(2))
            if path:
                current = path
            elif current is None:
                misses.append(f"{page.as_posix()}:{p_start + 1}: `{m.group(0)}` has no path to inherit")
                continue
            if current not in files:
                files[current] = (
                    (ROOT / current).read_text(encoding="utf-8").splitlines()
                    if (ROOT / current).is_file()
                    else None
                )
            content = files[current]
            cite = f"{current}:{a}" + (f"-{b}" if b != a else "")
            where = f"{key}:{p_start + 1}"
            if content is None and "/" not in current:
                # A bare file name that is not in the repository root: plugin or provider source.
                print(f"skip  {where}  {cite}  (external file name)")
                continue
            total += 1
            if content is None:
                misses.append(f"{where}: {cite} cites a file that does not exist in the repository")
                continue
            entry = (key, p_start + 1, cite)
            if entry in allow:
                seen.add(entry)
            if b > len(content) or a < 1 or a > b:
                misses.append(f"{where}: {cite} is outside the file ({len(content)} lines)")
                continue
            cited = "\n".join(content[a - 1:b])
            cited_idents = {t for t in IDENT_RE.findall(cited)} | set(
                re.findall(r"[A-Za-z][A-Za-z0-9]*(?:[_.-][A-Za-z0-9]+)+", cited)
            )
            hit = sorted(idents & cited_idents)
            if hit:
                print(f"ok    {where}  {cite}  ({hit[0]})")
                continue
            weak = prose_hit(prose, fragments(cited))
            if weak:
                print(f"ok~   {where}  {cite}  (prose {weak})")
            elif entry in allow:
                print(f"ok    {where}  {cite}  (allowed: {allow[entry]})")
            else:
                misses.append(f"{where} {cite}  # shares no identifier with its paragraph")
    print(f"{key}: {total} anchors checked, {len(misses)} misses")
    return misses


def slug(heading: str) -> str:
    text = re.sub(r"`", "", heading)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = text.lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def heading_slugs(path: Path) -> set[str]:
    slugs: dict[str, int] = {}
    out = set()
    in_fence = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        m = HEADING_RE.match(line)
        if not m:
            continue
        s = slug(m.group(2))
        n = slugs.get(s, 0)
        slugs[s] = n + 1
        out.add(s if n == 0 else f"{s}-{n}")
    # terraform-docs anchors such as <a name="input_x"></a>
    out |= set(re.findall(r'<a name="([^"]+)"></a>', path.read_text(encoding="utf-8")))
    return out


def check_links(page: Path) -> list[str]:
    broken: list[str] = []
    cache: dict[Path, set[str]] = {}
    for n, line in enumerate(page.read_text(encoding="utf-8").splitlines(), 1):
        for target in LINK_RE.findall(line):
            if re.match(r"[a-z]+:", target) or target.startswith("//"):
                continue
            file_part, _, frag = target.partition("#")
            dest = page if file_part == "" else (page.parent / file_part).resolve()
            if not dest.exists():
                broken.append(f"{page.as_posix()}:{n}: {target} (missing file)")
                continue
            if frag and dest.is_file():
                if dest not in cache:
                    cache[dest] = heading_slugs(dest)
                if frag not in cache[dest]:
                    broken.append(f"{page.as_posix()}:{n}: {target} (no heading #{frag})")
    return broken


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("pages", nargs="*", default=DEFAULT_PAGES)
    ap.add_argument("--links", action="store_true", help="also check relative links and fragments")
    args = ap.parse_args(argv)
    files: dict[str, list[str] | None] = {}
    allow, stale = load_allow()
    seen: set[tuple[str, int, str]] = set()
    misses: list[str] = []
    broken: list[str] = []
    for p in args.pages:
        page = (ROOT / p) if not Path(p).is_absolute() else Path(p)
        misses += check_anchors(page, files, allow, seen)
        if args.links:
            broken += check_links(page)
    checked_pages = {page_key((ROOT / p) if not Path(p).is_absolute() else Path(p)) for p in args.pages}
    stale += [
        f"{ALLOW_FILE.name}: {where}:{n} {cite} has no such anchor on that paragraph any more"
        for (where, n, cite) in sorted(allow)
        if where in checked_pages and (where, n, cite) not in seen
    ]
    if misses:
        print("\nMISSES (add a line to scripts/check-doc-anchors.allow once a miss is read and found correct):")
        print("\n".join(misses))
    if stale:
        print("\nSTALE ALLOW ENTRIES:")
        print("\n".join(stale))
    if broken:
        print("\nBROKEN LINKS:")
        print("\n".join(broken))
    print(f"\n{len(misses)} anchor misses, {len(stale)} stale allow entries, {len(broken)} broken links")
    return 1 if misses or stale or broken else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
