# AGENTS.md

Rules for every contributor and coding agent working in this repository, whatever tool
they use. Project engineering guidance — architecture, CI, the release process — lives in
`CLAUDE.md`; this file holds the AI attribution policy.

## AI attribution policy

An AI assistant must never be credited as a contributor. The list of AI assistants is
`AI_NAMES` (plus `MODEL_ERE` for model names) in `.githooks/branding-guard.sh`, the single
source of truth for every enforcement layer below. It is a deny list: any identity it does
not name passes.

### Prohibited

- An AI assistant (Claude, Anthropic, Codex, OpenAI, ChatGPT, Copilot, Cursor, Gemini, Grok,
  Antigravity, Jules, Kiro, Devin, Aider) or a model name (Opus, Sonnet, Haiku, Fable,
  GPT-n) as a commit **author** or **committer**, by name or by address.
- A contributor-credit trailer (`Co-authored-by`, `Assisted-by`, `Generated-by`, or a
  session-link trailer) that names an AI assistant or model. GitHub lists every co-author
  of a commit on `main` as a contributor.
- In PR descriptions, issues and comments: such a trailer line, or a "Generated with/by
  <AI assistant>" byline. The PR check enforces this for the PR body.

### Allowed

- Naming any tool, model, vendor or file anywhere else: commit subjects and bodies, branch
  and tag names, tag messages, PR titles, the rest of a PR body, docs and code. Write
  `CLAUDE.md`, `codex`, the dependency-update bot's name or a workflow path as they are;
  do not rephrase to avoid them.
- Humans, code-quality bots (CodeRabbit, Semgrep, SonarCloud), the dependency-update bot,
  release bots and the fix-loop bot (`auto-code-scanning-autofix[bot]`,
  `autofix@auto-code-scanning.invalid`) as author, committer or co-author.
- A DCO `Signed-off-by` line. It is not contributor credit, so it is not checked.

### Identity

- Every local commit must be authored **and** committed by the identity in
  `git config user.name` / `git config user.email`. The `commit-msg` hook checks this
  exactly; `pre-push` and CI check only the deny list, because they must accept commits
  GitHub and the repository's bots make.
- Never pass `--author`, and never set `GIT_AUTHOR_*` / `GIT_COMMITTER_*` to commit as
  anyone else.
- An AI assistant working here commits under the human or orchestrator identity it runs
  as, never under its own.

Tested by `scripts/tests/attribution-guard.test.sh`, which the Format Check job runs.

### Never bypass the guard

- Never use `--no-verify`. If a hook blocks you, remove the attribution — do not work
  around the hook.
- Never edit, delete or weaken anything in `.githooks/`, and never unset or repoint
  `core.hooksPath`, except in a reviewed pull request the maintainer asks for.
- Never run `lefthook install --reset-hooks-path` (or `--force`): it unsets
  `core.hooksPath` and silently disables the guard.

`LEFTHOOK=0` skips only the lefthook scanners (secret scan, fmt, Trivy, Checkov, tflint).
The attribution guard still runs.

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
| `commit-msg` hook | `.githooks/commit-msg` | An AI credit trailer; an AI author or committer; an author or committer that is not exactly the configured identity — at commit time | `--no-verify`; lines starting with `#`, which it treats as comments even when `git commit -m` keeps them |
| `pre-push` hook | `.githooks/pre-push` | Every outgoing commit's AI credit trailers and AI author or committer names and addresses. Also scans `#` lines | `--no-verify`; a clone that never ran `install.sh` |
| CI | `.github/workflows/commit-hygiene.yml` | The same commit checks on every branch and tag push and every PR, plus AI credit trailers and AI bylines in the PR body. The PR check runs `main`'s copy of the workflow and guard, so a PR cannot weaken it | Nothing done locally — the only layer `--no-verify` cannot skip. A direct push to `main` can rewrite its own check unless the `required-PR` ruleset is active |

## Terraform conventions

These apply to any agent changing Terraform here. The project guidance file has the detail.

- **Azure Verified Modules first.** For any new Azure resource, use an Azure Verified Module when the
  [index](https://azure.github.io/Azure-Verified-Modules/indexes/terraform/tf-resource-modules/) lists it as
  *Available*, pinned to an exact version. Otherwise use the azurerm resource, with variables shaped to the AVM
  interfaces (`lock`, `diagnostic_settings`, `role_assignments`, `managed_identities`, `tags`). Check its version
  constraints first: as of 2026-11-13, seven of the sixteen measured candidates declare `modtm`; Storage, Key Vault and
  network security group need a newer Terraform than the 1.9.8 that the consumer's CI and this repository's second Validate job run; and six (MySQL, Key Vault, Log Analytics workspace, CDN profile, Front Door WAF policy and autoscale setting) cap azurerm below this tree's `~> 5.6`, so those
  six cannot init here at all. Key Vault caps azurerm at `< 5.0`; the Application Insights component requires no azurerm.
- Migrate existing bespoke modules only when a planned change touches them.
- Every module declares `required_providers` with an upper bound.
- Environment-aware defaults leave the `optional()` default off and select the value in the `*_config` local.
- Regenerate terraform-docs READMEs (0.20.0) after changing any variable, output or resource.
