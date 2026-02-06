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

<!-- BEGIN_TF_DOCS -->
## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [azurerm_linux_web_app.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/linux_web_app) | resource |
| [azurerm_linux_web_app_slot.staging](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/linux_web_app_slot) | resource |
| [azurerm_monitor_autoscale_setting.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_autoscale_setting) | resource |
| [azurerm_service_plan.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/service_plan) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_always_on"></a> [always\_on](#input\_always\_on) | Keep the app always loaded (required for production) | `bool` | `true` | no |
| <a name="input_app_insights_connection_string_secret_uri"></a> [app\_insights\_connection\_string\_secret\_uri](#input\_app\_insights\_connection\_string\_secret\_uri) | Key Vault secret URI for App Insights connection string (versionless) | `string` | `""` | no |
| <a name="input_app_subnet_id"></a> [app\_subnet\_id](#input\_app\_subnet\_id) | ID of the App Service VNet integration subnet (from networking module) | `string` | n/a | yes |
| <a name="input_cdn_provider"></a> [cdn\_provider](#input\_cdn\_provider) | CDN provider for IP restrictions: 'cloudflare', 'azure\_front\_door', 'direct', or 'none' | `string` | `"none"` | no |
| <a name="input_custom_domain"></a> [custom\_domain](#input\_custom\_domain) | Custom domain for the WordPress site | `string` | n/a | yes |
| <a name="input_database_host"></a> [database\_host](#input\_database\_host) | MySQL server FQDN | `string` | n/a | yes |
| <a name="input_database_name"></a> [database\_name](#input\_database\_name) | MySQL database name | `string` | n/a | yes |
| <a name="input_database_password_secret_uri"></a> [database\_password\_secret\_uri](#input\_database\_password\_secret\_uri) | Key Vault secret URI for database password (versionless) | `string` | n/a | yes |
| <a name="input_database_username"></a> [database\_username](#input\_database\_username) | MySQL username | `string` | n/a | yes |
| <a name="input_docker_image_tag"></a> [docker\_image\_tag](#input\_docker\_image\_tag) | Tag for the WordPress Docker image | `string` | `"8.4"` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name (nonprod or production) | `string` | n/a | yes |
| <a name="input_front_door_enabled"></a> [front\_door\_enabled](#input\_front\_door\_enabled) | DEPRECATED: Use cdn\_provider instead. Whether Front Door is enabled. | `bool` | `true` | no |
| <a name="input_front_door_id"></a> [front\_door\_id](#input\_front\_door\_id) | Azure Front Door resource GUID (required when cdn\_provider = azure\_front\_door) | `string` | `""` | no |
| <a name="input_health_check_path"></a> [health\_check\_path](#input\_health\_check\_path) | Path for health check endpoint | `string` | `"/"` | no |
| <a name="input_key_vault_uri"></a> [key\_vault\_uri](#input\_key\_vault\_uri) | Key Vault URI for secret references | `string` | n/a | yes |
| <a name="input_location"></a> [location](#input\_location) | Azure region for resources | `string` | n/a | yes |
| <a name="input_plan_id"></a> [plan\_id](#input\_plan\_id) | ID of existing App Service Plan. If null, a new plan is created. | `string` | `null` | no |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name used in resource naming (lowercase, 2-24 chars) | `string` | n/a | yes |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Name of the resource group | `string` | n/a | yes |
| <a name="input_site_name"></a> [site\_name](#input\_site\_name) | Site name used for resource naming (lowercase, hyphens only) | `string` | n/a | yes |
| <a name="input_sku_name"></a> [sku\_name](#input\_sku\_name) | App Service Plan SKU (P1v3 recommended for production) | `string` | `"P1v3"` | no |
| <a name="input_storage_access_key_secret_uri"></a> [storage\_access\_key\_secret\_uri](#input\_storage\_access\_key\_secret\_uri) | Key Vault secret URI for storage access key (versionless) | `string` | n/a | yes |
| <a name="input_storage_account_name"></a> [storage\_account\_name](#input\_storage\_account\_name) | Storage account name for media uploads | `string` | n/a | yes |
| <a name="input_storage_container_name"></a> [storage\_container\_name](#input\_storage\_container\_name) | Storage container name for media uploads | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to all resources | `map(string)` | `{}` | no |
| <a name="input_use_shared_plan"></a> [use\_shared\_plan](#input\_use\_shared\_plan) | Set to true when using a shared App Service Plan. This avoids plan-time unknown value issues. | `bool` | `false` | no |
| <a name="input_worker_count"></a> [worker\_count](#input\_worker\_count) | Number of workers (instances) | `number` | `1` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_custom_domain_verification_id"></a> [custom\_domain\_verification\_id](#output\_custom\_domain\_verification\_id) | Custom domain verification ID for DNS TXT record (asuid.<subdomain>) |
| <a name="output_default_hostname"></a> [default\_hostname](#output\_default\_hostname) | Default hostname of the Web App |
| <a name="output_id"></a> [id](#output\_id) | ID of the Linux Web App |
| <a name="output_name"></a> [name](#output\_name) | Name of the Linux Web App |
| <a name="output_plan_id"></a> [plan\_id](#output\_plan\_id) | ID of the App Service Plan (created or existing) |
| <a name="output_principal_id"></a> [principal\_id](#output\_principal\_id) | Principal ID of the Web App managed identity |
| <a name="output_staging_slot_hostname"></a> [staging\_slot\_hostname](#output\_staging\_slot\_hostname) | Hostname of the staging deployment slot (null if SKU doesn't support slots) |
| <a name="output_staging_slot_id"></a> [staging\_slot\_id](#output\_staging\_slot\_id) | ID of the staging deployment slot (null if SKU doesn't support slots) |
| <a name="output_tenant_id"></a> [tenant\_id](#output\_tenant\_id) | Tenant ID of the Web App managed identity |
<!-- END_TF_DOCS -->
