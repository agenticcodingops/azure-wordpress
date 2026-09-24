# AGENTS.md

Rules for every contributor and coding agent working in this repository, whatever tool
they use. Project engineering guidance — architecture, CI, the release process — lives in
`CLAUDE.md`; this file holds the commit-metadata policy.

## Commit metadata policy

Third-party vendor and AI-tool names must not appear in version-control metadata. The
authoritative list is `BRANDING_ERE` in `.githooks/branding-guard.sh`, the single source
of truth for every enforcement layer below.

**In scope:** commit messages, commit trailers, tag messages, branch names, PR titles,
PR bodies, and author/committer identity.

**Out of scope:** file content, filenames, dependencies and documentation. This repo
legitimately ships workflows and docs that name such products. Do not rename or edit
files to satisfy this policy.

### Prohibited

- Attribution trailers — `Co-Authored-By`, `Assisted-By`, `Generated-By`, session-link
  trailers — that name a tool or model, or carry a bot or noreply address.
- Bylines and footers such as "Generated with …", and the robot emoji.
- A vendor or tool name anywhere in a subject, body, branch name, tag or PR text.
  Naming a file whose path contains one trips the guard too, so describe the file
  instead ("the agent settings file", "the project guidance file").
- A model name used as an author, co-author or trailer identity.

### Identity

- Every commit must be authored **and** committed by the identity in
  `git config user.name` / `git config user.email`, and that address must be listed in
  `.githooks/allowed-authors.txt`. The list's other entries exist only so that merges
  made on github.com pass CI; the comments in the file say which is which.
- Never add a bot address to the list. The guard rejects `[bot]` and `bot@` addresses
  before it reads the list, so the entry would do nothing.
- Never pass `--author`, and never set `GIT_AUTHOR_*` / `GIT_COMMITTER_*` to commit as
  anyone else.

### Never bypass the guard

- Never use `--no-verify`. If a hook blocks you, rewrite the message — do not work
  around the hook.
- Never edit, delete or weaken anything in `.githooks/`, and never unset or repoint
  `core.hooksPath`.
- Never run `lefthook install --reset-hooks-path` (or `--force`): it unsets
  `core.hooksPath` and silently disables the guard.

`LEFTHOOK=0` skips only the lefthook scanners (secret scan, fmt, Trivy, Checkov, tflint).
The commit-metadata guard still runs.

## Setup — once per clone

```bash
sh .githooks/install.sh
```

This sets `core.hooksPath=.githooks`. That is local git config, never cloned, so every
fresh clone needs it. The hooks in `.githooks/` also run the lefthook scanners, so do
**not** run `lefthook install` as well.

## Enforcement layers

| Layer | Where | What it catches | What gets past it |
| --- | --- | --- | --- |
| Agent settings | `.claude/settings.json` (`attribution`) | Stops that agent from adding trailers, bylines or session links in the first place | Any other tool, or a human |
| `commit-msg` hook | `.githooks/commit-msg` | Branded message, unlisted author or committer — at commit time | `--no-verify`; lines starting with `#`, which it treats as comments even when `git commit -m` keeps them |
| `pre-push` hook | `.githooks/pre-push` | Every outgoing commit's message and both identities, ref names, annotated tag messages. Also scans `#` lines | `--no-verify`; a clone that never ran `install.sh` |
| CI | `.github/workflows/commit-hygiene.yml` | The same scan on every push and PR, plus the PR title and body | Nothing done locally — the only layer `--no-verify` cannot skip |
