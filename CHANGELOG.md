# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
