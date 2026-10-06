# v1 to v2

This page is the **v2.0.0** break (2026-08-02), the changelog's compare from v1.3.2. Releases from v1.0.0 through v1.3.2 are not restated here.

## Expected plan

Both [`CHANGELOG.md`](../../CHANGELOG.md) and the [v2.0.0 release notes](https://github.com/agenticcodingops/azure-wordpress/releases/tag/v2.0.0) record these breaking changes:

- Key Vault and Storage now deny public data-plane access by default.
- Six object attributes on the site module no longer carry a default, so leaving them unset selects a value by environment instead of the old fixed value.

The changelog upgrade path, copied below, states these plan effects:

- `database.geo_redundant_backup` now resolves `true` in production, and the attribute is `ForceNew`. The changelog says changing it on an existing server plans a **destroy and recreate**, and `modules/database` sets `prevent_destroy = false`.
- `database.sku_name` resolving `B_Standard_B2s` in nonprod is, in the changelog, "a downgrade-on-upgrade that forces replacement."
- `backup_retention_days` (production 7 to 30), `monitoring.retention_days` (production 30 to 90), and `app_service.health_check_path` (`/` to `/wp-includes/images/blank.gif`) are, in the changelog, "online and non-destructive."
- The Key Vault and Storage default of denying public access is described as 403s. The changelog does not say whether that plan replaces or destroys those resources. **UNKNOWN.**
- Item 2 of the copied upgrade path offers `storage_network_rules_default_action = "Allow"` as the media fix. The moved site-module note qualifies it: `Allow` removes the firewall gate only. The uploads container stays private and the storage plugin writes unsigned URLs, so anonymous browsers still cannot read media. See [Moved from the site module](#moved-from-the-site-module).

The release notes repeat the Key Vault and Storage bullet, list commit `27443d7` on the same bugfix subject as `#19`, and do not include the upgrade-path section. They do not state a further plan diff.

The module note moved below calls the nonprod SKU change "a compute tier change that forces a restart." The changelog calls it replacement. The note is right: the provider documents `sku_name` on `azurerm_mysql_flexible_server` without "forces a new resource" ([azurerm provider docs](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/mysql_flexible_server)), so a tier change is an in-place update with a restart, not a replacement.

## Changelog entry

Copied unchanged from [`CHANGELOG.md`](../../CHANGELOG.md). This change replaced that upgrade-path section, in the changelog, with a link to this page. The copy below is the section as it stood, with one edit: its link to the site-module README pointed at a heading this change moved, so it now points to [Moved from the site module](#moved-from-the-site-module).

## [2.0.0](https://github.com/agenticcodingops/azure-wordpress/compare/v1.3.2...v2.0.0) (2026-08-02)


### ⚠ BREAKING CHANGES

* Key Vault and Storage now deny public data-plane access by default.
* **wordpress-site:** six object attributes no longer carry a default, so consumers that leave them unset now get environment-selected values instead of the old fixed ones.

### 🚑 Upgrade path — read before applying

Four new defaults will take a working site down if adopted blind. All are opt-out; none
require a code change. Full detail in [`modules/wordpress-site/README.md`](#moved-from-the-site-module).

**1. Key Vault denies public access → your pipeline gets 403.** Terraform is not a trusted
Azure service, so its data-plane calls that create secrets are refused. GitHub-hosted runners
have a rotating egress range that cannot practically be allow-listed.

```hcl
key_vault_public_network_access_enabled = true   # deploying from hosted CI
```

**2. Storage denies public access → media 403s for every visitor.** The WordPress Blob
Storage plugin rewrites media URLs to the storage account's own blob endpoint, so **end
users** fetch media directly from Azure, from arbitrary IPs that can never be allow-listed.
This breaks images site-wide, not just deployment.

```hcl
storage_network_rules_default_action = "Allow"   # unless the blob endpoint is behind a CDN custom domain
```

**3. `database.geo_redundant_backup` now resolves `true` in production.** Previously always
`false`. Three ways this bites: some regions have **no geo-backup target at all** (Sweden
Central reports `supportedGeoBackupRegions: []`) and the apply fails; it is **unsupported on
the Burstable tier**; and it is **`ForceNew`**, so changing it on an existing server plans a
**destroy and recreate** with `prevent_destroy = false`.

```hcl
database = { geo_redundant_backup = false }      # keep pre-v2.0.0 behaviour
```

**4. `database.sku_name` now resolves `B_Standard_B2s` in nonprod** instead of
`GP_Standard_D2ds_v4` — a downgrade-on-upgrade that forces replacement. Pin it if you relied
on the old behaviour.

Also environment-aware, all online and non-destructive: `backup_retention_days` (production
7 → 30), `monitoring.retention_days` (production 30 → 90), `app_service.health_check_path`
(`/` → `/wp-includes/images/blank.gif`).

### Features

* **wordpress-site:** activate environment-aware defaults ([#21](https://github.com/agenticcodingops/azure-wordpress/issues/21)) ([ee3615f](https://github.com/agenticcodingops/azure-wordpress/commit/ee3615f8b6549e2adf5f3beb9337cbd34237bba8))
* **wordpress-site:** add extra_secrets and extra_secret_app_settings pass-through ([6287b5f](https://github.com/agenticcodingops/azure-wordpress/commit/6287b5f2e685d9a18d07b42b09f6930e908a6167))


### Bug Fixes

* **app-service:** use an allow-list for deployment-slot tier detection ([9edabcf](https://github.com/agenticcodingops/azure-wordpress/commit/9edabcfef8b3220f355819b21800a98821ef9aba))
* pin providers and deny public data-plane access by default ([#19](https://github.com/agenticcodingops/azure-wordpress/issues/19)) ([8d81c74](https://github.com/agenticcodingops/azure-wordpress/commit/8d81c74c8aec607fd3e8fac92e4d228b03800561))

## Moved from the site module

The wording below is the former section of `modules/wordpress-site/README.md`. Links that pointed at headings in that file, or at `docs/` from that file, now use a path from this directory.

## ⚠️ Upgrading to v2.0.0 — read before you apply

v2.0.0 changes four defaults in ways that **will take a working site down** if you upgrade
without setting them. All four are opt-out; none require a code change.

### 1. Key Vault denies public access → Terraform gets 403

`network_acls.default_action` now defaults to `Deny`. Terraform is **not** a trusted Azure
service, so its data-plane calls that create secrets are refused. GitHub-hosted runners have
a large, rotating egress range that cannot practically be allow-listed.

```hcl
# Deploying from hosted CI (GitHub Actions, Azure DevOps hosted agents):
key_vault_public_network_access_enabled = true

# Or, with a self-hosted runner on a stable IP or inside the VNet:
key_vault_network_acls_ip_rules                   = ["203.0.113.10"]
key_vault_network_acls_virtual_network_subnet_ids = [azurerm_subnet.runner.id]
```

The site's own App Service subnet is allow-listed automatically, so `@Microsoft.KeyVault(...)`
references keep resolving either way. This only affects the deploying principal.

### 2. Storage denies public access → media 403s for every visitor

`network_rules.default_action` now defaults to `Deny`. This is the easiest one to under-read:
the WordPress Blob Storage plugin rewrites media URLs to the storage account's **own** blob
endpoint, so **end users' browsers fetch media directly from Azure** — from arbitrary
consumer IPs that can never be allow-listed. With `Deny`, those fetches return 403.

```hcl
# Removes the firewall gate for browsers that fetch from the blob endpoint:
storage_network_rules_default_action = "Allow"
```

`Allow` removes the firewall gate only. The storage module also sets
`allow_nested_items_to_be_public = false` (`modules/storage/main.tf:28`) and creates the uploads container as
`private` (`modules/storage/main.tf:91`); neither is an input of this module. Azure then rejects every anonymous
read, so an anonymous browser still cannot read a blob, and media loads only from a SAS-signed URL. The Microsoft
Azure Storage for WordPress plugin writes unsigned URLs. See
[Security model: Key Vault and Storage deny public access by default](../security-model.md#key-vault-and-storage-deny-public-access-by-default)
and [Architecture: Media](../architecture.md#media).

A CDN custom domain in front of the blob endpoint helps only if the CDN itself authenticates to the account;
otherwise its origin requests are anonymous too. In that design keep `Deny` and allow-list the CDN's egress
ranges via `storage_network_rules_ip_rules`. When `cdn_provider = "cloudflare"`, Cloudflare's live IPv4 ranges
are added automatically. They matter only for origin pulls through a Cloudflare custom domain, which this module
does not create, and not for direct browser fetches.

### 3. `database.geo_redundant_backup` now resolves `true` in production

Previously this was always `false` regardless of environment. If you never set it explicitly,
production now requests geo-redundant backup, and there are three ways that bites:

- **Not all regions have a geo-backup target.** Sweden Central reports
  `supportedGeoBackupRegions: []`, so the apply fails outright.
- **Unsupported on the Burstable tier** (`B_*` SKUs) entirely.
- **It is `ForceNew`.** Azure can only choose geo-redundancy at creation, so changing it on
  an existing server plans a **destroy and recreate**, and `modules/database` sets
  `prevent_destroy = false`.

```hcl
database = {
  geo_redundant_backup = false   # keep pre-v2.0.0 behaviour
}
```

Check your region first: `az mysql flexible-server list-skus -l <region> --query "[].supportedGeoBackupRegions"`.

### 4. `database.sku_name` now resolves `B_Standard_B2s` in nonprod

Previously every environment got `GP_Standard_D2ds_v4`. Nonprod now gets Burstable — a
**downgrade on upgrade** for anyone relying on the old accidental behaviour, and a compute
tier change that forces a restart. Pin it if you were depending on General Purpose:

```hcl
database = {
  sku_name = "GP_Standard_D2ds_v4"
}
```

### Everything else

`backup_retention_days` (production 7 → 30), `monitoring.retention_days` (production 30 → 90)
and `app_service.health_check_path` (`/` → `/wp-includes/images/blank.gif`) also become
environment-aware. All are online, non-destructive changes.

