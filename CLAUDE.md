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

# Compliance scan (see Checkov section below)
checkov -d . --framework terraform --quiet

# Regenerate a module's README (CI enforces fail-on-diff)
terraform-docs markdown table --indent 2 --output-mode inject --output-file README.md \
  --output-template '<!-- BEGIN_TF_DOCS -->
{{ .Content }}
<!-- END_TF_DOCS -->' modules/<module>
```

## Architecture

**Two-layer deployment model with explicit `depends_on`:**

```
Layer 1 (Foundation):  networking → dns-zones
Layer 2 (Application): database, storage, key-vault → app-service → front-door/cloudflare
```

App Insights is created early (between layers) to break a circular dependency — its connection string must be in Key Vault before App Service is created.

**Composition module** (`modules/wordpress-site`) orchestrates everything. Consumers pass high-level objects (`database = {}`, `storage = {}`, `app_service = {}`) and the composition module fans out to sub-modules with environment-aware defaults.

**Environment-aware defaults** in the composition module (not the sub-modules):
- Production: 30-day backup retention, geo-redundant backup, GP_Standard_D2ds_v4 SKU, WAF Prevention mode, 90-day log retention
- Nonprod: 7-day retention, no geo-redundancy, B_Standard_B2s SKU, WAF Detection mode, 30-day log retention

These only fire for attributes whose `optional()` declaration carries **no default**, so
`null` reaches the `coalesce()` in `main.tf`. An `optional(number, 7)` would make the
environment branch unreachable — this was a real bug through v1.3.2, where every one of
these defaults was dead code. When adding an environment-aware default, leave the object
attribute's default off and select in the `*_config` local.

**Shared plan pattern:** Multiple sites share one App Service Plan via `app_service.use_shared_plan = true`. Azure requires the App Service and Plan to be in the same resource group, so the composition module switches to `shared_resource_group_name` when this is set.

**CDN provider pattern:** Single `cdn_provider` variable controls which CDN is active: `"cloudflare"`, `"azure_front_door"`, or `"direct"`. Only one is created. Front Door uses `azapi_update_resource` to inject the FD GUID into IP restrictions after creation (avoids circular dependency).

## Checkov skip_check Format

**CRITICAL:** The `bridgecrewio/checkov-action` entrypoint uses unquoted `$INPUT_SKIP_CHECK`, causing bash word splitting. Always use a single comma-separated string with NO spaces:

```yaml
skip_check: CKV_TF_1,CKV_TF_2,CKV_AZURE_225
```

Never use `>-` folded scalar or spaces after commas — it breaks the skip list silently.

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

`validate.yml` triggers **only on pushes and PRs targeting `main`**. A stacked PR (base = another feature branch) runs none of Format/Validate/Checkov/Documentation — only Semgrep and the reusable scan. Verify stacked work locally (below) and retarget to `main` before relying on CI.

## Provider Version Pinning

**Every module must declare `required_providers` with an upper bound.** Lock files are gitignored and CI runs `tofu init -backend=false` fresh, so an unconstrained module resolves the newest major and breaks:

- `azurerm` is pinned `~> 4.0`. On 5.x, six of eleven modules fail to validate (`enable_rbac_authorization` → `rbac_authorization_enabled`, subnet `service_endpoints` removed, `private_dns_zone_name` → `private_dns_zone_id`, `minimum_tls_version`/`behavior_on_match` removed).
- `cloudflare` is pinned `~> 5.0`. `data.cloudflare_ip_ranges` renamed its attributes across majors: 4.x exposes `ipv4_cidr_blocks`/`ipv6_cidr_blocks`, 5.x exposes `ipv4_cidrs`/`ipv6_cidrs`. This repo uses the 5.x names.

Nine modules carry a `versions.tf`; `wordpress-site` and `shared-infrastructure` declare theirs inline in `main.tf`. Adding a module without constraints reintroduces the breakage silently — it only surfaces when a new provider major ships.

## Static Analysis Constraints

**Checkov and Trivy resolve a plain variable's `default`, but cannot see through an `optional()` attribute inside an object-typed variable.** A secure default written as `storage = { network_rules_default_action = optional(string, "Deny") }` is reported as a misconfiguration (CKV_AZURE_35); the same default on a top-level variable passes. Verified: literal → pass, plain variable → pass, object attribute → fail, `coalesce()` via a `local` → fail.

This is why the Key Vault and Storage network settings are **top-level variables** (`key_vault_network_acls_*`, `storage_network_rules_*`) rather than attributes on the `key_vault`/`storage` objects. Keep security-relevant defaults flat.

Terraform itself has the same indirection, with a sharper consequence: an `optional()` default is substituted **before** the value reaches any `coalesce()`, so `coalesce(var.database.backup_retention_days, ...)` can never see `null` while that attribute declares `optional(number, 7)`. Any environment-aware default written that way is dead code. Leave the object attribute's default off and select in the `*_config` local.

## Network Posture

Key Vault and Storage **deny public data-plane access by default**. Two consequences that break deploys if unhandled:

- **Terraform is not a trusted Azure service.** Its data-plane calls create the Key Vault secrets, so they 403 unless the deploying principal is reachable — set `key_vault_network_acls_ip_rules` to the runner's egress IP, or `key_vault_public_network_access_enabled = true`. The site's App Service subnet is allow-listed automatically (it carries the `Microsoft.KeyVault` service endpoint), so Key Vault references keep resolving.
- **Media bypasses the CDN.** The WordPress Blob Storage plugin rewrites media URLs to `<account>.blob.core.windows.net`, so browsers fetch from Azure directly, from IPs that cannot be allow-listed. Unless the blob endpoint is fronted by a CDN custom domain, set `storage_network_rules_default_action = "Allow"`.

`key_vault_public_network_access_enabled` drives **only** `network_acls.default_action` — the module never sets the ARM-level `public_network_access_enabled` argument. This is a firewall on a live public endpoint, not a private-endpoint configuration, so IP rules and service-endpoint subnets apply normally.

When `cdn_provider = "cloudflare"`, Cloudflare's live IPv4 egress ranges are added to the storage allow-list via `data.cloudflare_ip_ranges`. IPv6 is omitted deliberately: Azure Storage IP rules are IPv4-only and also reject `/31`–`/32` prefixes.

## Replacement Hazards

`azurerm_mysql_flexible_server.geo_redundant_backup_enabled` is **ForceNew** — Azure can only choose geo-redundancy at creation. Changing it on an existing server produces a plan that destroys and recreates it, and `modules/database` sets `prevent_destroy = false`. Never change this default without an explicit migration note. `sku_name` is *not* ForceNew: tier changes (including General Purpose → Burstable) are an in-place resize with a 60–120s restart.

## Composition vs Standalone Modules

`modules/wordpress-site` does **not** instantiate `modules/monitoring`. It creates the Log Analytics Workspace and Application Insights inline so the App Insights connection string is available for Key Vault before App Service exists. Consequences:

- The standalone `monitoring` module enforces a production floor of `max(var.retention_days, 90)`; the composition applies its own environment-aware default with **no floor**.
- Changes to `modules/monitoring` do not affect consumers of `wordpress-site`.

`modules/database` similarly has a `null_resource` guard rejecting Burstable SKUs in production, but the composition hardcodes `enforce_production_sku = false`, so that guard is unreachable through `wordpress-site`.

## Reproducing CI Locally

Pin to the exact versions CI uses, or results diverge:

```bash
# Clean-room validate — mirrors CI, which has no lock file
rm -rf modules/*/.terraform modules/*/.terraform.lock.hcl
for m in modules/*/; do (cd "$m" && terraform init -backend=false >/dev/null && terraform validate); done

# Checkov 3.3.8 (CI's version) with the exact skip list from validate.yml
pip install checkov==3.3.8
python -m checkov.main -d . --quiet --framework terraform --compact --skip-check <list-from-validate.yml>

# terraform-docs 0.20.0 — the version terraform-docs/gh-actions@v1.4.1 bundles.
# Regeneration is idempotent; an untouched module must produce a zero diff.

# Trivy at the pre-commit hook's severity
trivy config . --severity CRITICAL --skip-dirs .terraform
```

Local hooks run via **lefthook**, not pre-commit (`lefthook install`). Pre-commit runs secret scanning, `terraform fmt` and Trivy CRITICAL on changed directories only; pre-push adds Checkov and tflint. Missing tools fail open with a warning. Disable with `LEFTHOOK=0 git commit`, or `global.local_hooks_enabled: false` in `scan-config.yaml`. Note the hooks scan **changed directories**, so touching a previously untouched module can surface pre-existing findings.

`docs/` and `tests/` exist but are empty — there is no test suite, and `docs/runbooks/database-snapshot.md` referenced from `modules/database/main.tf` does not exist.
