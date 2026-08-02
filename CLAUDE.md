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
- Production: 30-day backup retention, geo-redundant backup, GP_Standard_D2ds_v4 SKU, WAF Prevention mode
- Nonprod: 7-day retention, no geo-redundancy, B_Standard_B2s SKU, WAF Detection mode

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
