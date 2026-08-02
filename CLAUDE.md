# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Reusable Terraform/OpenTofu modules for deploying WordPress on Azure. The consumer repo (trackroutinely) calls the composition module at `modules/wordpress-site`, which orchestrates 10 sub-modules in a two-layer dependency model.

## Commands

```bash
# Format (CI uses OpenTofu 1.6.0, terraform fmt produces identical output)
tofu fmt -recursive -check -diff
terraform fmt -recursive

# Validate a module (must init first, no backend needed)
cd modules/<module> && terraform init -backend=false && terraform validate

# Security scan
trivy config . --severity HIGH,CRITICAL

# Compliance scan. Checkov is deliberately NOT on PATH here (it would arm a dormant
# pre-push hook) — see "Reproducing CI Locally" for the pinned, suffixed invocation.
checkov -d . --framework terraform --quiet

# Regenerate a module's README (CI enforces fail-on-diff)
terraform-docs markdown table --indent 2 --output-mode inject --output-file README.md \
  --output-template '<!-- BEGIN_TF_DOCS -->
{{ .Content }}
<!-- END_TF_DOCS -->' modules/<module>
```

## Architecture

**Two-layer deployment model with explicit `depends_on`:**

```text
Layer 1 (Foundation):  networking → dns-zones
Layer 2 (Application): database, storage, key-vault → app-service → front-door/cloudflare
```

App Insights is created early (between layers) to break a circular dependency — its connection string must be in Key Vault before App Service is created.

**Composition module** (`modules/wordpress-site`) orchestrates everything. Consumers pass high-level objects (`database = {}`, `storage = {}`, `app_service = {}`) and the composition module fans out to sub-modules with environment-aware defaults.

**Environment-aware defaults** in the composition module (not the sub-modules):

- Production: 30-day backup retention, geo-redundant backup, GP_Standard_D2ds_v4 SKU, WAF Prevention mode, 90-day log retention, Key Vault purge protection on with 90-day soft-delete retention
- Nonprod: 7-day retention, no geo-redundancy, B_Standard_B2s SKU, WAF Detection mode, 30-day log retention, Key Vault purge protection off with 7-day soft-delete retention

These only fire for attributes whose `optional()` declaration carries **no default**, so
`null` reaches the `coalesce()` in `main.tf`. An `optional(number, 7)` would make the
environment branch unreachable — this was a real bug through v1.3.2, where every one of
these defaults was dead code. When adding an environment-aware default, leave the object
attribute's default off and select in the `*_config` local.

**Shared plan pattern:** Multiple sites share one App Service Plan via `app_service.use_shared_plan = true`. Azure requires the App Service and Plan to be in the same resource group, so the composition module switches to `shared_resource_group_name` when this is set.

**CDN provider pattern:** Single `cdn_provider` variable controls which CDN is active: `"cloudflare"`, `"azure_front_door"`, or `"direct"`. Only one is created. Front Door uses `azapi_update_resource` to inject the FD GUID into IP restrictions after creation (avoids circular dependency).

## Checkov skip_check Format

Use a single comma-separated string with NO spaces:

```yaml
skip_check: CKV_TF_1,CKV_TF_2,CKV_AZURE_225
```

Never use a `>-` folded scalar — a multi-line skip list is not reassembled the way you expect.

> **Corrected 2026-08-02.** This file previously claimed the action's entrypoint uses an
> unquoted `$INPUT_SKIP_CHECK` and word-splits. That is **not true of the pinned image**:
> `checkov 3.3.9`'s `github_action_resources/entrypoint.sh` builds `declare -a CKV_ARGS` via
> an `add_csv` helper with every expansion quoted, splitting on comma only, and it even trims
> one leading/trailing space per token. Keep the no-spaces convention (it is harmless and
> portable), but do not reach for word splitting to explain a skip-list bug — it is not the
> mechanism.

## terraform-docs

All module READMEs use `<!-- BEGIN_TF_DOCS -->` / `<!-- END_TF_DOCS -->` markers. CI runs `terraform-docs/gh-actions@v1.4.1` (which bundles terraform-docs 0.20.0) with `fail-on-diff: true` across all 11 modules. After changing any variable, output, or resource, regenerate the README for that module.

Do NOT leave `.terraform/` or `.terraform.lock.hcl` in module directories when running terraform-docs — lock files cause provider versions to resolve differently than CI (which runs without `terraform init`).

## Key Patterns

**WordPress container:** Uses `mcr.microsoft.com/appsvc/wordpress-debian-php`. This container expects `DATABASE_HOST`, `DATABASE_NAME`, `DATABASE_USERNAME`, `DATABASE_PASSWORD` env vars (NOT the standard `WORDPRESS_DB_*` names). The app-service module constructs these internally from its input variables.

**Secret management:** Database password generated via `random_password`, stored in Key Vault, referenced by App Service via `@Microsoft.KeyVault(SecretUri=...)`. Both production and staging slot managed identities get Key Vault Get/List access.

**Staging slots:** Only created on Standard (S\*) and Premium (P\*) SKUs. Detection: `can(regex("^(S|P)[0-9]", var.sku_name))` — an allow-list, so an unrecognised tier fails closed rather than erroring at apply. Free (F1) and Shared (D1) have no slots either, though `sku_name`'s validation regex already rejects them. The slot gets its own managed identity and auto-generated `WP_HOME`/`WP_SITEURL` pointing to the staging hostname.

**Naming convention:** `{resource-type}-{project_name}-{site_name}-{env_suffix}` where env_suffix is `np` (nonprod) or `prod` (production). Storage accounts: `sttr{site_abbrev}{env_suffix}` (alphanumeric only, 3-24 chars).

## Module Source Pinning

Examples and consumer repos use `?ref=v<VERSION>` for stability.

**Releases are cut by release-please, never by hand.** Merging a conventional commit to `main` makes release-please open a `chore(main): release X.Y.Z` PR; merging *that* PR creates the tag and GitHub Release. `fix:` bumps patch, `feat:` minor, `feat!:`/`BREAKING CHANGE:` major; `docs:`/`chore:` do not bump at all. Do not run `git tag` — it desyncs `.release-please-manifest.json` and `CHANGELOG.md`.

Update the `?ref=` references in README.md and examples/ to the version being released as part of the change itself, since release-please does not rewrite the examples.

## CI Pipeline (.github/workflows/validate.yml)

Four jobs: Format Check (tofu fmt), Validate (11 modules), Checkov, Documentation (terraform-docs). All must pass before merge. IaC misconfiguration scanning is covered by the Terraform Security Scan workflow (Trivy IaC + Checkov + tflint); the standalone tfsec job was removed (EOL, folded into Trivy; aquasecurity org IP allow-list 403s the action download on runners).

**`claude-review` fails on every PR — the `CLAUDE_CODE_OAUTH_TOKEN` secret is expired, not the workflow.**
`main` has no branch protection, so nothing is gated on it and prior PRs merged with it red. Don't
chase it as a regression from your change.

> **Corrected 2026-08-02.** This file previously blamed an empty `ANTHROPIC_API_KEY`. That is the
> wrong secret: `claude-code-review.yml` passes `claude_code_oauth_token`, and `ANTHROPIC_API_KEY`
> is *expected* to be empty. The workflow is fine and needs no edit.

Evidence, in case it regresses again — the failure is deliberately hard to read, because the action
logs only `Claude execution failed: result is_error:true` and hides the message ("full output hidden
for security"). Debug mode does **not** lift that redaction; only `show_full_output: true` does.
Diagnose from the result record instead:

- **Expired credential:** `num_turns: 1`, `duration_ms` ≈ 2000, `total_cost_usd: 0` — rejected before
  any billable token. A genuine review reports 3–16 turns and a non-zero cost.
- Runs here succeeded through **2026-06-15** on this same token, then every run from 2026-08-02
  onward failed — 18 in a row across 9.6 h.
- Same day, same `anthropics/claude-code-action@v1`, same Claude Code v2.1.220, same
  `claude-sonnet-5`, byte-identical workflow: `agenticcodingops/agentic-research-stack` **passed** at
  15:51 mid-window. The only difference is token age. That mid-window success also rules out an
  account-wide usage limit, which would be time-boxed and hit every repo at once.
- The same expiry hit `auto-code-scanning` and `multi-ai-deep-research-pipeline` on 2026-07-26; both
  were fixed by rotating the secret and passed seconds later. This repo was missed.

Rotate it (the value cannot be recovered — it must be re-minted):

```bash
claude setup-token   # interactive; prints a fresh token
gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo agenticcodingops/azure-wordpress   # paste at the prompt
```

`agenticcodingops/trackroutinely` still carries a token from 2026-01-24 and has never had a green
Claude run — rotate it there too.

**Do not edit `claude-code-review.yml` to test this.** The action verifies the workflow file is
byte-identical to the copy on the default branch; any PR that touches it makes the action *skip*
with "Workflow validation failed" and report **green** without reviewing anything. Several of this
workflow's historical "successes" are exactly that — a skip, not a review.

`validate.yml` triggers **only on pushes and PRs targeting `main`**. A stacked PR (base = another feature branch) runs none of Format/Validate/Checkov/Documentation — only Semgrep and the reusable scan. Verify stacked work locally (below) and retarget to `main` before relying on CI.

## Landing Stacked Work

**Do not stack PRs in this repo.** On 2026-08-02 a three-PR stack silently lost an entire release:

| PR | Base | Merged |
|---|---|---|
| #19 | `main` | 10:20:22 |
| #20 | `fix/pin-azurerm-4x` | 10:21:28 |
| #21 | `feat/key-vault-extra-secrets` | 10:21:47 |

PR #19 was squash-merged into `main`, which deleted its head branch. PRs #20 and #21 then
merged into branches that no longer fed anywhere. Both show **MERGED** in the GitHub UI;
neither reached `main`. The gap went unnoticed until a later session found `extra_secrets` absent
from `main` and re-landed all five commits via #23. Meanwhile release-please had already
opened a release PR proposing a **major** version carrying the breaking network changes and
none of the features that justified them.

Three compounding traps, each of which hid the failure:

1. **A squash-merge makes the base diverge.** The squash is a new commit object holding the
   same tree, so `git diff --stat <original> <squash>` prints nothing while the two are
   ancestrally unrelated. A stacked branch still carrying the pre-squash original merges
   cleanly wherever its later commits touch *different hunks*, and conflicts only where a
   later delta overlaps a region the squash also rewrote — so a conflict is possible, not
   guaranteed. In #23 exactly one file conflicted (`modules/wordpress-site/main.tf`); every
   other file both sides had touched auto-merged.

2. **Detect conflicts with `merge-tree --write-tree`, not the legacy three-argument form.**
   The legacy form *does* emit markers, but as unified-diff additions (`+<<<<<<< .our`), so
   an anchored `grep '^<<<<<<<'` reports zero and reads as "clean". The modern form exits
   non-zero on conflict, names the paths, and touches neither the worktree nor any branch —
   no scratch branch to clobber:

   Exit status is the signal: **0** clean, **1** conflict, other values an error whose output
   is unspecified. Measured here (git 2.54): unrelated histories give **128**, so branch on
   the status rather than using `if`/`else`. But **1 is not exclusively "conflict"** — an
   unresolvable ref also exits 1, printing `not something we can merge` on *stderr*. Redirect
   only stdout, so that message stays visible.

   Capture the status immediately and re-exit with it. If you branch on `$?` and let the
   conflict arm end in a `… | sed` pipeline, the script's own status becomes `sed`'s — **0** —
   so wired into a gate it reports conflicts and then passes. Fail closed on the fetch too, or
   you silently check a stale `origin/main` and get a false clean:

   ```bash
   #!/usr/bin/env bash
   # conflict-check.sh <branch> — exit 0 clean, 1 conflict (or bad ref: see stderr), 2 no fetch
   branch=$1
   git fetch -q origin || { echo "fetch failed — refusing to check a stale ref" >&2; exit 2; }
   git merge-tree --write-tree origin/main "$branch" >/dev/null   # stderr deliberately not redirected
   status=$?
   case $status in
     0) echo "clean" ;;
     1) git merge-tree --write-tree --name-only origin/main "$branch" | sed -n '2,/^$/p' ;;
     *) echo "merge-tree errored — check the refs" >&2 ;;
   esac
   exit $status          # NOT the pipeline's status
   ```

3. **A conflicted PR gets no `pull_request` workflow runs.** GitHub cannot build the merge
   ref, so every `pull_request`-triggered workflow is skipped. Measured on #23: while it was
   `CONFLICTING` there were **zero** runs against its head SHA — not `validate.yml`, not
   `terraform-scan.yml`, and not `semgrep.yml` or `claude-code-review.yml` either, even though
   those two carry no `branches:` filter.

   The scope matters: workflows on *other* triggers are unaffected. `claude.yml` fires on
   `issue_comment` / `pull_request_review_comment`, so `@claude` still answers on a conflicted
   PR — which makes it look alive while the gates that matter never ran.

   Mergeability alone does not prove any of this — a PR can pass CI and *later* go
   `CONFLICTING`/`DIRTY` when `main` moves, which does not erase the earlier runs. Query by
   the exact head SHA rather than by branch, or stale runs on older SHAs come back and are
   easy to misread as current:

   ```bash
   head_sha="$(git rev-parse HEAD)"
   gh api "repos/agenticcodingops/azure-wordpress/actions/runs?head_sha=${head_sha}" \
     -q '.workflow_runs[] | "\(.conclusion // .status)\t\(.name)"'
   ```

**Instead:** target `main` directly, one PR at a time; merge each fully and let release-please
settle before opening the next.

**Merge vs squash.** Prefer a **merge commit** only when *every* commit in the PR is a real
release unit, so each `feat:`/`fix:` subject reaches `main` and earns its own changelog entry.
If the branch carries `wip`/`fixup`/`address review comments` noise, **squash** instead —
release-please parses every subject that lands, and a merge would drag the noise into the
changelog. That is why release-please's own default recommendation is squash-merge.

**Recovering an already-stacked branch** — two options, with a real trade-off:

- *Merge `origin/main` into the branch and resolve there.* Keeps every commit message
  verbatim, but leaves both the pre-squash commit and its squash as ancestors, so
  release-please counts the change twice. On #23 that produced a duplicate `fix:` line **and**
  a duplicate `BREAKING CHANGE:` bullet in #22, both removed by hand before releasing. Budget
  for that edit.
- *Rebuild on `main` with only the unlanded commits* —
  `git rebase --onto origin/main <squashed-base> <branch>`. No duplicate entries, but it
  rewrites SHAs, so force-push and re-request review.

  `<squashed-base>` is **the pre-squash commit on your branch whose content already reached
  `main` via the squash** — not `origin/main`, and not the squash commit. `rebase --onto`
  replays "commits in `<branch>` not in `<upstream>`", so naming that commit is what excludes
  the already-landed work. Confirm before running it:

  Confirm it against the **squash commit** — `<squash-commit>`, the commit the base PR
  produced on `main` — not against `origin/main` itself. `origin/main` is a moving tip: any
  unrelated commit landing after the squash makes the diff non-empty even when your base is
  correct. (Measured: `git diff --stat 27443d7 origin/main` reports 20 files today, versus
  empty against `8d81c74`.) Three separate checks:

  ```bash
  git diff --stat <squashed-base> <squash-commit>              # empty  = same content, right base
  git merge-base --is-ancestor <squash-commit> origin/main \
    && echo "squash is on main"                                # confirms it actually landed
  git log --oneline <squashed-base>..<branch>                  # must list ONLY unlanded commits
  ```

  Worked example from #23: `<squashed-base>` was `27443d7` and `<squash-commit>` was `8d81c74`
  — identical trees. Using the merge-base (`fd952bc`) instead would have replayed `27443d7`
  as well and reintroduced the very duplicate this option exists to avoid.

Keep the subjects intact either way — release-please parses them.

## Provider Version Pinning

**Every module must declare `required_providers` with an upper bound.** Lock files are gitignored and CI runs `tofu init -backend=false` fresh, so an unconstrained module resolves the newest major and breaks:

- `azurerm` is pinned `~> 4.0`. On 5.x, six of eleven modules fail to validate (`enable_rbac_authorization` → `rbac_authorization_enabled`, subnet `service_endpoints` removed, `private_dns_zone_name` → `private_dns_zone_id`, `minimum_tls_version`/`behavior_on_match` removed).
- `cloudflare` is pinned `~> 5.0`. `data.cloudflare_ip_ranges` renamed its attributes across majors: 4.x exposes `ipv4_cidr_blocks`/`ipv6_cidr_blocks`, 5.x exposes `ipv4_cidrs`/`ipv6_cidrs`. This repo uses the 5.x names.

Nine modules carry a `versions.tf`; `wordpress-site` and `shared-infrastructure` declare theirs inline in `main.tf`. Adding a module without constraints reintroduces the breakage silently — it only surfaces when a new provider major ships.

## Static Analysis Constraints

**Checkov and Trivy resolve a plain variable's `default`, but cannot see through an `optional()` attribute inside an object-typed variable.** A secure default written as `storage = { network_rules_default_action = optional(string, "Deny") }` is reported as a misconfiguration (CKV_AZURE_35); the same default on a top-level variable passes. Verified: literal → pass, plain variable → pass, object attribute → fail.

This is why the Key Vault and Storage network settings are **top-level variables** (`key_vault_network_acls_*`, `storage_network_rules_*`) rather than attributes on the `key_vault`/`storage` objects. Keep security-relevant defaults flat.

**An unresolvable value does not automatically fail — it depends on the check's base class.** This file previously generalised "`coalesce()` via a `local` → fail" from CKV_AZURE_35. That generalisation is wrong:

- Checks deriving from `BaseResourceValueCheck` call `_is_variable_dependant()` *before* the equality test and return **UNKNOWN**, which is neither a pass nor a failure.
- `CKV_AZURE_35` fails instead only because its check body is a bare string equality with no variable guard.

Measured when v3.0.0 introduced `coalesce(var.key_vault_purge_protection_enabled, var.environment == "production")`: CKV_AZURE_110 moved PASSED → UNKNOWN, CKV_AZURE_42 stayed PASSED, and the run went **0 failed → 0 failed**. CI stayed green with no skip added. The real cost is silent: a check that used to be enforced simply stops being evaluated.

**So: measure, don't assume.** Run checkov `-d .` from the repo root (never `-d modules/<x>` alone — the at-risk instance is the one rendered through the `module` call, and Checkov reports only that nested instance) before and after, and diff the failed-check sets. Do not pre-emptively add a skip.

Terraform itself has the same indirection, with a sharper consequence: an `optional()` default is substituted **before** the value reaches any `coalesce()`, so `coalesce(var.database.backup_retention_days, ...)` can never see `null` while that attribute declares `optional(number, 7)`. Any environment-aware default written that way is dead code. Leave the object attribute's default off and select in the `*_config` local.

## Network Posture

Key Vault and Storage **deny public data-plane access by default**. Two consequences that break deploys if unhandled:

- **Terraform is not a trusted Azure service.** Its data-plane calls create the Key Vault secrets, so they 403 unless the deploying principal is reachable — set `key_vault_network_acls_ip_rules` to the runner's egress IP, or `key_vault_public_network_access_enabled = true`. The site's App Service subnet is allow-listed automatically (it carries the `Microsoft.KeyVault` service endpoint), so Key Vault references keep resolving.
- **Media bypasses the CDN.** The WordPress Blob Storage plugin rewrites media URLs to `<account>.blob.core.windows.net`, so browsers fetch from Azure directly, from IPs that cannot be allow-listed. Unless the blob endpoint is fronted by a CDN custom domain, set `storage_network_rules_default_action = "Allow"`.

`key_vault_public_network_access_enabled` drives **only** `network_acls.default_action` — the module never sets the ARM-level `public_network_access_enabled` argument. This is a firewall on a live public endpoint, not a private-endpoint configuration, so IP rules and service-endpoint subnets apply normally.

When `cdn_provider = "cloudflare"`, Cloudflare's live IPv4 egress ranges are added to the storage allow-list via `data.cloudflare_ip_ranges`. IPv6 is omitted deliberately: Azure Storage IP rules are IPv4-only and also reject `/31`–`/32` prefixes.

## Replacement Hazards

`azurerm_mysql_flexible_server.geo_redundant_backup_enabled` is **ForceNew** — Azure can only choose geo-redundancy at creation. Changing it on an existing server produces a plan that destroys and recreates it, and `modules/database` sets `prevent_destroy = false`. Never change this default without an explicit migration note. `sku_name` is *not* ForceNew: tier changes (including General Purpose → Burstable) are an in-place resize with a 60–120s restart.

**Key Vault (v3.0.0) — the sharpest trap in the repo, because failure is an errored apply, not just data loss:**

- `purge_protection_enabled` is one-way. Azure permits `false → true` **in place**, but never `true → false`; the reverse forces replacement. The asymmetry matters — hardening later is free.
- `soft_delete_retention_days` "can only be configured one time and cannot be updated" — any change forces replacement.
- **Replacing the vault fails unless `key_vault_name_suffix` is bumped in the same change.** Terraform destroys before it creates; the old vault soft-deletes still holding its name, and azurerm's `recover_soft_deleted_key_vaults` **defaults to `true`**, so the create step *recovers the old vault* rather than creating one — with purge protection still on, which the new config then tries to disable. Azure refuses.
- A purge-protected soft-deleted vault locks its name for the full retention window against **everyone**: `az keyvault purge` returns `MethodNotAllowed` even for subscription Owner. No role or flag shortens it.
- Recovery restores a vault **in its original region**. Reusing a name while changing `location` silently strands Key Vault in the old region — a data-residency violation. Always bump `key_vault_name_suffix` when changing region.
- With purge protection *off*, none of this applies: `purge_soft_delete_on_destroy` (default `true`) purges on destroy and frees the name immediately.

Vault names are capped at 24 chars — `kv-{site≤14}-{env}{suffix}` — so a long site name plus a 3-char suffix overflows.

## Composition vs Standalone Modules

`modules/wordpress-site` does **not** instantiate `modules/monitoring`. It creates the Log Analytics Workspace and Application Insights inline so the App Insights connection string is available for Key Vault before App Service exists. Consequences:

- The standalone `monitoring` module enforces a production floor of `max(var.retention_days, 90)`; the composition applies its own environment-aware default with **no floor**.
- Changes to `modules/monitoring` do not affect consumers of `wordpress-site`.

`modules/database` similarly has a `null_resource` guard rejecting Burstable SKUs in production, but the composition hardcodes `enforce_production_sku = false`, so that guard is unreachable through `wordpress-site`.

## Verifying a Change Without Azure Credentials

There is no test suite, and a real `terraform plan` needs credentials (`modules/key-vault` has `data "azurerm_client_config"`). Two techniques cover almost everything; both are offline and neither touches the repo.

**1. `terraform console` for expression semantics.** Run against the real module, not a copy, with `TF_DATA_DIR` pointed outside the repo. This is how you prove an environment-aware default actually fires:

```bash
export TF_DATA_DIR=<scratch>/tfdata
terraform -chdir=modules/wordpress-site init -backend=false
BASE="-var project_name=x -var site_name=x -var location=eastus \
      -var tenant_id=00000000-0000-0000-0000-0000000000aa -var custom_domain=x.example.com"
echo 'jsonencode({raw=var.<new_var>, resolved=local.<x>_config})' \
  | terraform -chdir=modules/wordpress-site console $BASE -var environment=production
```

Wrap in `jsonencode()` — bare `null` prints as a blank line and is easy to misread as "no output". Confirm the raw variable is `null` (or the `coalesce` fallback is dead code) and that an explicit `false` survives: `coalesce` skips `null` but **keeps `false` and `0`**, and skips `""`. Delete any `.terraform.lock.hcl` it leaves behind.

**2. `terraform test` with `mock_provider` for a real plan.** Mocks the whole credential surface — with `cdn_provider = "direct"` the only live data source in the tree is `data.azurerm_client_config.current`, so one `mock_data` block suffices. The strongest available proof of backward compatibility is a **before/after plan differential**: extract `origin/main` and your working tree with `git archive` (use `git stash create` for the latter, so both sides are extracted identically and line-ending differences don't show up as spurious diffs), drop a byte-identical fixture in each, share one `.terraform.lock.hcl`, and diff the `-verbose` output. An empty diff means no plan change.

Two constraints, both discovered the hard way:

- The fixture **must** use a B-tier SKU (`app_service = { sku_name = "B1" }`). On S\*/P\* SKUs `azurerm_key_vault_access_policy.staging_slot` has `count = module.app_service.staging_slot_principal_id != null ? 1 : 0`, which is unknown at plan time on a greenfield plan — Terraform rejects it outright. `examples/basic-site` already uses B1.
- Guard against vacuous results: an empty diff between two *failures* is also empty. Assert exit code 0, grep that the resource was positively planned, and grep its actual attribute values.

Limits worth stating in any report: these are greenfield **create** plans, so they prove identical planned *arguments*, not provider-side diffing against real state — and mocks bypass `PlanResourceChange`, so **`# forces replacement` is invisible**. ForceNew claims must be sourced from the provider docs, not from these plans.

## Reproducing CI Locally

Pin to the exact versions CI uses, or results diverge:

```bash
# Clean-room validate — mirrors CI, which has no lock file
rm -rf modules/*/.terraform modules/*/.terraform.lock.hcl
for m in modules/*/; do (cd "$m" && terraform init -backend=false >/dev/null && terraform validate); done

# Checkov — CI runs 3.3.9, from `runs.image` in bridgecrewio/checkov-action@v12's
# action.yml. v12 is a MOVING tag: re-read action.yml rather than trusting this number.
#   gh api repos/bridgecrewio/checkov-action/contents/action.yml?ref=<v12-sha> \
#     --jq '.content' | base64 -d | grep image:
# Install SUFFIXED so plain `checkov` stays off PATH — see the hook warning below.
pipx install --suffix=@339 checkov==3.3.9
checkov@339 -d . --framework terraform -o json --skip-check <list-from-validate.yml>
# Drop --quiet when comparing before/after: it hides PASSED and UNKNOWN, which is
# exactly the signal you need (see Static Analysis Constraints).

# terraform-docs 0.20.0 — the version terraform-docs/gh-actions@v1.4.1 bundles.
# Regeneration is idempotent; an untouched module must produce a zero diff.

# Trivy at the pre-commit hook's severity
trivy config . --severity CRITICAL --skip-dirs .terraform
```

Local hooks run via **lefthook**, not pre-commit (`lefthook install`). Pre-commit runs secret scanning, `terraform fmt` and Trivy CRITICAL on changed directories only; pre-push adds Checkov and tflint. Missing tools fail open with a warning. Disable with `LEFTHOOK=0 git commit`, or `global.local_hooks_enabled: false` in `scan-config.yaml`. Note the hooks scan **changed directories**, so touching a previously untouched module can surface pre-existing findings.

**Installing Checkov arms a hook that is currently dormant.** `hooks/checkov.sh` does `require_tool checkov || exit 0`, so with Checkov absent from PATH the pre-push gate is a silent no-op. It also resolves `.checkov.yaml` from `.scanning/configs/`, which does not exist — so when it *does* run it runs with **no skip list at all**, and will flag many of the 23 checks `validate.yml` deliberately skips. Those findings are pre-existing and unrelated to your change; do not "fix" them. Keep Checkov off PATH (the `pipx --suffix` above), or use `LEFTHOOK=0 git push` once and say so in the PR. Do **not** commit `local_hooks_enabled: false` (repo-wide, disables the mandatory secret gate), and do **not** add a `.checkov.yaml` without also wiring `validate.yml` to it — that would create a third divergent policy source.

`docs/` and `tests/` exist but are empty — there is no test suite (see "Verifying a Change Without Azure Credentials" above for what to do instead), and `docs/runbooks/database-snapshot.md` referenced from `modules/database/main.tf:109` does not exist.
