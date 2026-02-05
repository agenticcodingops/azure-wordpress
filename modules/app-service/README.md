# App Service Module

Layer 2 Application module for WordPress on Linux App Service.

## Overview

This module creates:
- Linux Web App with Docker container
- Optional App Service Plan (or use shared)
- Staging deployment slot
- VNet integration for database access
- System-assigned managed identity
- Auto-scale rules

## CRITICAL: No Storage Mount

**DO NOT add `storage_account` block** for `/var/www/html`.

Azure Files mounts cause 2-3 second latency per page load. Instead:
- WordPress is baked into the Docker image (immutable)
- Media uploads use Blob Storage via plugin
- Configuration via app settings (not file mounts)

## Sticky Settings

The following settings are sticky to deployment slots:
- `WP_HOME` - WordPress home URL
- `WP_SITEURL` - WordPress site URL
- `WP_DEBUG` - Debug mode

This ensures staging slot uses staging URL, not production URL.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| site_name | Site name | string | - | yes |
| environment | Environment | string | - | yes |
| location | Azure region | string | - | yes |
| resource_group_name | Resource group | string | - | yes |
| app_subnet_id | App subnet ID | string | - | yes |
| plan_id | Existing plan ID (null = create new) | string | null | no |
| sku_name | App Service Plan SKU | string | "P1v3" | no |
| always_on | Keep app loaded | bool | true | no |
| database_host | MySQL server FQDN | string | - | yes |
| database_name | MySQL database name | string | - | yes |
| database_username | MySQL username | string | - | yes |
| key_vault_uri | Key Vault URI | string | - | yes |
| database_password_secret_uri | DB password secret URI | string | - | yes |
| storage_account_name | Storage account name | string | - | yes |
| storage_container_name | Storage container name | string | - | yes |
| storage_access_key_secret_uri | Storage key secret URI | string | - | yes |
| custom_domain | Custom domain | string | - | yes |
| tags | Resource tags | map(string) | {} | no |

## Outputs

| Name | Description |
|------|-------------|
| id | Web App ID |
| name | Web App name |
| default_hostname | Default hostname |
| principal_id | Managed identity principal ID |
| plan_id | App Service Plan ID |
| staging_slot_id | Staging slot ID |

## Usage

```hcl
module "app_service" {
  source = "../modules/layer-2-application/app-service"

  site_name           = "workout-tracker"
  environment         = "nonprod"
  location            = "East US"
  resource_group_name = azurerm_resource_group.main.name

  app_subnet_id = module.networking.app_subnet_id

  database_host     = module.database.server_fqdn
  database_name     = module.database.database_name
  database_username = "wpadmin"

  key_vault_uri                = module.key_vault.uri
  database_password_secret_uri = module.key_vault.secret_versionless_uris["db-password"]

  storage_account_name          = module.storage.account_name
  storage_container_name        = module.storage.container_name
  storage_access_key_secret_uri = module.key_vault.secret_versionless_uris["storage-key"]

  custom_domain = "workout-staging.trackroutinely.com"

  tags = local.tags
}
```

## Deployment Slots

Rolling updates via deployment slots:
1. Deploy to staging slot
2. Test staging slot
3. Swap staging ↔ production
4. Rollback by swapping again

## Validation Rules

The module enforces these validations at plan time:

| Variable | Rule | Error Message |
|----------|------|---------------|
| `site_name` | `^[a-z0-9-]+$` | Site name must contain only lowercase letters, numbers, and hyphens |
| `environment` | `nonprod` or `production` | Environment must be 'nonprod' or 'production' |
| `sku_name` | `^(B\|S\|P)[0-9]v?[0-9]?$` | SKU must be a valid App Service Plan SKU (e.g., B1, S1, P1v3) |
| `worker_count` | 1-30 | Worker count must be between 1 and 30 |
