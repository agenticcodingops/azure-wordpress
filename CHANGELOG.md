# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.1.0](https://github.com/agenticcodingops/azure-wordpress/compare/v3.0.0...v3.1.0) (2026-08-08)


### Features

* harden the SCM/Kudu plane, expose basic-auth publishing controls, re-export database_server_name ([#30](https://github.com/agenticcodingops/azure-wordpress/issues/30)) ([b860e9e](https://github.com/agenticcodingops/azure-wordpress/commit/b860e9e3f31f5692b4f940e4cbbdf5e5fad2b7be))

## [3.0.0](https://github.com/agenticcodingops/azure-wordpress/compare/v2.0.0...v3.0.0) (2026-08-02)


### ⚠ BREAKING CHANGES

* **wordpress-site:** nonprod deployments that leave both new inputs unset get a Key Vault destroy-and-recreate. Azure permits enabling purge protection but never disabling it, and soft_delete_retention_days cannot be updated after creation, so Terraform can only reach the new values by replacing the vault. The apply fails unless key_vault_name_suffix is bumped in the same change, because the soft-deleted vault still holds the name and the provider recovers it rather than creating a new one. Set key_vault_purge_protection_enabled = true and key_vault_soft_delete_retention_days = 90 to keep the previous behaviour. Production consumers are unaffected.

### 🚑 Upgrade path — read before applying

**Production consumers who set neither new variable are unaffected** — the resolved values
are still `true` and `90`, exactly what the module hardcoded before. Verified as an empty
plan diff. Nothing to do.

**Nonprod deployments that leave both new inputs unset will replace their Key Vault, and
the apply fails if you do nothing.** Terraform destroys before it creates; the old vault
soft-deletes still holding its name, and because azurerm's `recover_soft_deleted_key_vaults`
defaults to `true`, the create step then *recovers that old vault* — with purge protection
still on, which the new configuration tries to disable. Azure refuses.

Pick one before upgrading:

```hcl
# A. Keep pre-v3.0.0 behaviour exactly. No replacement, no plan diff.
key_vault_purge_protection_enabled   = true
key_vault_soft_delete_retention_days = 90

# B. Adopt the new nonprod defaults, and give the new vault a free name in the same apply.
key_vault_name_suffix = "12"   # any value not already soft-deleted
```

Under option B no secret value is lost: `random_password.db` has no `keepers`, so the
database password is preserved and re-written into the new vault (**it is not rotated**);
`storage-key` and `appinsights-connection` are re-read from the untouched live resources;
`extra_secrets` are re-uploaded from your own configuration. Mind the 24-character vault
name limit, `kv-{site≤14}-{env}{suffix}`.

Note the asymmetry: only *disabling* purge protection forces replacement. Turning it back
**on** for a nonprod vault later is a free in-place update.

Full detail in [`modules/wordpress-site/README.md`](modules/wordpress-site/README.md#️-upgrading-to-v300--read-before-you-apply).

### Features

* **wordpress-site:** expose Key Vault purge protection and soft-delete retention ([#24](https://github.com/agenticcodingops/azure-wordpress/issues/24)) ([354bd9c](https://github.com/agenticcodingops/azure-wordpress/commit/354bd9c2b442614ddd3de8236970014d70fce66d))
* **wordpress-site:** expose `app_service_principal_id`, removing the need for a consumer to re-read the site with a `data "azurerm_linux_web_app"` block ([354bd9c](https://github.com/agenticcodingops/azure-wordpress/commit/354bd9c2b442614ddd3de8236970014d70fce66d))

## [2.0.0](https://github.com/agenticcodingops/azure-wordpress/compare/v1.3.2...v2.0.0) (2026-08-02)


### ⚠ BREAKING CHANGES

* Key Vault and Storage now deny public data-plane access by default.
* **wordpress-site:** six object attributes no longer carry a default, so consumers that leave them unset now get environment-selected values instead of the old fixed ones.

### 🚑 Upgrade path — read before applying

Four new defaults will take a working site down if adopted blind. All are opt-out; none
require a code change. Full detail in [`modules/wordpress-site/README.md`](modules/wordpress-site/README.md#-upgrading-to-v200--read-before-you-apply).

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

## [1.3.2](https://github.com/agenticcodingops/azure-wordpress/compare/v1.3.1...v1.3.2) (2026-06-12)


### Bug Fixes

* **cloudflare:** ignore zone_id changes on page rules to prevent forced replacement ([#14](https://github.com/agenticcodingops/azure-wordpress/issues/14)) ([ba23376](https://github.com/agenticcodingops/azure-wordpress/commit/ba2337647f59ecc738f65502a1d07dc077490920))

## [1.3.1](https://github.com/agenticcodingops/azure-wordpress/compare/v1.3.0...v1.3.1) (2026-05-17)


### Bug Fixes

* **monitoring:** add app_service_plan_id variable ([e7c181f](https://github.com/agenticcodingops/azure-wordpress/commit/e7c181f920d4aabbb2690948258dd6f01adf38ec))
* **monitoring:** scope high_cpu alert to App Service Plan ([398cbed](https://github.com/agenticcodingops/azure-wordpress/commit/398cbed689a0c708fbac8104496c73e50ae7d7b6))
* **monitoring:** scope high_cpu alert to App Service Plan ([463e1ac](https://github.com/agenticcodingops/azure-wordpress/commit/463e1acc4f1e9bd40aa0aa284bbbb3c040cb1501))
* **monitoring:** scope high_cpu alert to App Service Plan ([6774761](https://github.com/agenticcodingops/azure-wordpress/commit/67747612f914d6e5ff6ddafc7aadf3919ece1642))

## [1.3.0](https://github.com/agenticcodingops/azure-wordpress/compare/v1.2.0...v1.3.0) (2026-05-17)


### Features

* Add configurable key_vault_name_suffix to avoid soft-delete conflicts ([459b5d4](https://github.com/agenticcodingops/azure-wordpress/commit/459b5d42523c02c2be601702c90eaee567b7999f))


### Bug Fixes

* **app-service:** fetch live Cloudflare IPs at apply time, protect staging slot ([3de7594](https://github.com/agenticcodingops/azure-wordpress/commit/3de75948cc762da4d917bac1e8dbeb0df06a664d))
* **app-service:** fetch live Cloudflare IPs at apply time, protect staging slot ([832acd9](https://github.com/agenticcodingops/azure-wordpress/commit/832acd903710c1e9ca6527df614a2a00ee4031fe))
* **app-service:** replace index() with ip_restriction.key in dynamic blocks ([18a2680](https://github.com/agenticcodingops/azure-wordpress/commit/18a2680c7515e30c5361773d4222dc2d1c100628))
* use CpuPercentage instead of CpuTime for high CPU alert metric ([9755189](https://github.com/agenticcodingops/azure-wordpress/commit/97551899ecb5b33e0528873ed6be21d8e8f78f75))

## [1.2.0](https://github.com/agenticcodingops/azure-wordpress/compare/v1.1.0...v1.2.0) (2026-05-17)


### Features

* Add configurable key_vault_name_suffix to avoid soft-delete conflicts ([459b5d4](https://github.com/agenticcodingops/azure-wordpress/commit/459b5d42523c02c2be601702c90eaee567b7999f))


### Bug Fixes

* pre-launch hardening for WP-Cron, health checks, page rules, and resource locks ([a4039fd](https://github.com/agenticcodingops/azure-wordpress/commit/a4039fd434b7660ac1e53c774898b7d2c3b87ecc))
* use CpuPercentage instead of CpuTime for high CPU alert metric ([9755189](https://github.com/agenticcodingops/azure-wordpress/commit/97551899ecb5b33e0528873ed6be21d8e8f78f75))

## [1.1.0](https://github.com/agenticcodingops/azure-wordpress/compare/v1.0.0...v1.1.0) (2026-05-17)


### Features

* Add configurable key_vault_name_suffix to avoid soft-delete conflicts ([459b5d4](https://github.com/agenticcodingops/azure-wordpress/commit/459b5d42523c02c2be601702c90eaee567b7999f))
* add release-please automation for semantic versioning ([f2a2068](https://github.com/agenticcodingops/azure-wordpress/commit/f2a206809e32b74ba8aa06031eb87e02d15c3dc9))
* enhance app service and database modules with additional settings and lifecycle management features ([72f3e0e](https://github.com/agenticcodingops/azure-wordpress/commit/72f3e0e65c2fece882fcd046a5e64860503c8dcf))
* **wordpress-site:** expose backup, storage lifecycle, and staging slot variables ([695d5e9](https://github.com/agenticcodingops/azure-wordpress/commit/695d5e96d080628a21bddc025857cd8148c5411d))


### Bug Fixes

* **ci:** use PAT token for release-please PR creation ([5e6e8e3](https://github.com/agenticcodingops/azure-wordpress/commit/5e6e8e3405778cffce8a5b6a6a460a5c240a99ef))
* correct formatting for additional containers and lifecycle management parameters in storage module README ([19b0f9d](https://github.com/agenticcodingops/azure-wordpress/commit/19b0f9dc189557ff806d407e97ccab0f8c5bf476))
* correct terraform formatting in multi-site example ([3146a6b](https://github.com/agenticcodingops/azure-wordpress/commit/3146a6b4f9337f3ce562677d1280537689f45c00))
* pre-launch hardening for WP-Cron, health checks, page rules, and resource locks ([a4039fd](https://github.com/agenticcodingops/azure-wordpress/commit/a4039fd434b7660ac1e53c774898b7d2c3b87ecc))
* update skip_check rules in Checkov job for improved security compliance ([168b188](https://github.com/agenticcodingops/azure-wordpress/commit/168b188a715739d306db842fb30d33b50f97d592))
* use CpuPercentage instead of CpuTime for high CPU alert metric ([9755189](https://github.com/agenticcodingops/azure-wordpress/commit/97551899ecb5b33e0528873ed6be21d8e8f78f75))

## [Unreleased]

## [1.1.0] - 2026-03-29

### Added

#### Backup & Recovery

- **database**: `storage_auto_grow_enabled` variable for MySQL auto-grow storage (default: true)
- **storage**: `versioning_enabled` variable to control blob versioning (default: true)
- **storage**: `blob_delete_retention_days` variable for soft-delete retention (default: 30)
- **storage**: `container_delete_retention_days` variable for container soft-delete (default: 30)
- **storage**: `additional_containers` variable to create extra containers (e.g., wp-backups for UpdraftPlus)
- **storage**: `additional_container_names` output for created container names

#### Storage Lifecycle Management

- **storage**: `lifecycle_policy_enabled` variable to enable/disable lifecycle rules (default: true)
- **storage**: `lifecycle_cool_tier_days` variable for Cool tier tiering threshold (default: 30)
- **storage**: `lifecycle_version_delete_days` variable for version cleanup (default: 90)
- **storage**: `lifecycle_snapshot_delete_days` variable for snapshot cleanup (default: 90)
- **storage**: `lifecycle_prefix_match` variable to scope lifecycle rules to prefixes (default: ["uploads/"])

#### Staging Deployment Slots

- **app-service**: `extra_app_settings` variable for custom app settings merged with built-in WordPress settings
- **app-service**: `extra_sticky_app_setting_names` variable for additional slot-sticky setting names
- **app-service**: `sticky_connection_string_names` variable for sticky connection strings
- **app-service**: `staging_app_settings_override` variable for staging-specific setting overrides
- **app-service**: `staging_always_on` variable to control staging slot always-on (default: false)
- **app-service**: `staging_slot_principal_id` output for staging slot managed identity

#### Composition Module (wordpress-site)

- **wordpress-site**: New `storage` variable object exposing all storage configuration
- **wordpress-site**: Pass-through of all new sub-module variables (database, storage, app-service)
- **wordpress-site**: Key Vault access policy for staging slot managed identity
- **wordpress-site**: `staging_slot_principal_id` output
- **wordpress-site**: `storage_additional_container_names` output

### Changed

- **storage**: Blob properties (versioning, retention) now configurable via variables instead of hardcoded
- **storage**: Lifecycle management policy now configurable via variables instead of hardcoded values
- **storage**: Lifecycle policy is now conditional via `lifecycle_policy_enabled`

### Fixed

- **CI**: Added `CKV_AZURE_34` to Checkov skip list (false positive -- storage account already enforces `allow_nested_items_to_be_public = false`)

## [1.0.0] - 2024-01-15

### Added

- Initial release of azure-wordpress

#### Core Modules
- **wordpress-site** - Complete WordPress deployment composition module
- **shared-infrastructure** - Shared App Service Plan for multi-site deployments
- **app-service** - Azure App Service (Linux) with managed WordPress container
- **database** - Azure MySQL Flexible Server with Private Endpoint
- **storage** - Azure Blob Storage for WordPress media uploads
- **key-vault** - Azure Key Vault for secrets management with managed identity
- **networking** - Virtual Network and subnet configuration
- **dns-zones** - Private DNS zones for internal resolution
- **monitoring** - Application Insights and alerting configuration

#### CDN Modules
- **cloudflare** - Cloudflare DNS, CDN, and WAF integration
- **front-door** - Azure Front Door CDN with WAF (enterprise option)

#### Features
- Multi-site deployment on shared App Service Plans for cost optimization
- Private endpoint connectivity for MySQL database
- Managed identity authentication (no credentials in code)
- Key Vault references for runtime secret injection
- Cloudflare IP restriction for origin protection
- TLS 1.2 minimum enforcement across all services
- Comprehensive monitoring with Application Insights
- Support for custom domains with automated SSL

#### Documentation
- Complete module documentation with examples
- Architecture diagrams (text and Mermaid)
- Cost optimization guide
- CDN comparison matrix

[Unreleased]: https://github.com/agenticcodingops/azure-wordpress/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/agenticcodingops/azure-wordpress/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/agenticcodingops/azure-wordpress/releases/tag/v1.0.0
