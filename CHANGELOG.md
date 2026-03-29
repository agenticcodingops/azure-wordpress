# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
