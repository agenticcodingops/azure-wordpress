# Storage Module

Layer 2 Application module for Blob Storage (WordPress media uploads).

## Overview

This module creates:
- Storage Account with blob versioning
- Container for WordPress uploads (wp-uploads)
- CORS rules for media access

## IMPORTANT: No Azure Files Mount

This module creates Blob Storage for WordPress media uploads via plugin.
**DO NOT use Azure Files mounts** for `/var/www/html` - this causes:
- 2-3 second page load latency
- Poor IOPS for PHP file operations
- Timeout issues with WordPress admin

Instead, we use:
- Immutable container (WordPress baked into image)
- Azure Blob Storage for media uploads
- Microsoft Azure Storage plugin for WordPress

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| site_name | Site name for resource naming | string | - | yes |
| environment | Environment (nonprod/production) | string | - | yes |
| location | Azure region | string | - | yes |
| resource_group_name | Resource group name | string | - | yes |
| account_tier | Storage tier (Standard/Premium) | string | "Standard" | no |
| account_replication_type | Replication type | string | "LRS" | no |
| container_name | Blob container name | string | "wp-uploads" | no |
| tags | Resource tags | map(string) | {} | no |

## Outputs

| Name | Description |
|------|-------------|
| account_id | Storage Account ID |
| account_name | Storage Account name |
| primary_blob_endpoint | Blob endpoint URL |
| container_name | Container name |
| primary_access_key | Access key (sensitive) |

## Usage

```hcl
module "storage" {
  source = "../modules/layer-2-application/storage"

  site_name           = "workout-tracker"
  environment         = "nonprod"
  location            = "East US"
  resource_group_name = azurerm_resource_group.main.name

  tags = local.tags
}
```

## WordPress Configuration

Configure the Microsoft Azure Storage plugin:
- Account Name: `module.storage.account_name`
- Container: `module.storage.container_name`
- Access Key: Store in Key Vault

## Validation Rules

The module enforces these validations at plan time:

| Variable | Rule | Error Message |
|----------|------|---------------|
| `site_name` | `^[a-z0-9-]+$` | Site name must contain only lowercase letters, numbers, and hyphens |
| `environment` | `nonprod` or `production` | Environment must be 'nonprod' or 'production' |
| `account_tier` | `Standard` or `Premium` | Account tier must be 'Standard' or 'Premium' |
| `account_replication_type` | `LRS`, `GRS`, `RAGRS`, `ZRS`, `GZRS`, `RAGZRS` | Invalid replication type |
| `container_name` | `^[a-z0-9-]+$` | Container name must contain only lowercase letters, numbers, and hyphens |

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
| [azurerm_storage_account.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_account) | resource |
| [azurerm_storage_container.additional](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_container) | resource |
| [azurerm_storage_container.uploads](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_container) | resource |
| [azurerm_storage_management_policy.lifecycle](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_management_policy) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_account_replication_type"></a> [account\_replication\_type](#input\_account\_replication\_type) | Storage account replication type | `string` | `"LRS"` | no |
| <a name="input_account_tier"></a> [account\_tier](#input\_account\_tier) | Storage account tier (Standard or Premium) | `string` | `"Standard"` | no |
| <a name="input_additional_containers"></a> [additional\_containers](#input\_additional\_containers) | Map of additional blob containers to create (e.g., wp-backups for UpdraftPlus) | <pre>map(object({<br>    access_type = optional(string, "private")<br>  }))</pre> | `{}` | no |
| <a name="input_blob_delete_retention_days"></a> [blob\_delete\_retention\_days](#input\_blob\_delete\_retention\_days) | Number of days to retain soft-deleted blobs (1-365) | `number` | `30` | no |
| <a name="input_container_delete_retention_days"></a> [container\_delete\_retention\_days](#input\_container\_delete\_retention\_days) | Number of days to retain soft-deleted containers (1-365) | `number` | `30` | no |
| <a name="input_container_name"></a> [container\_name](#input\_container\_name) | Name of the blob container for WordPress uploads | `string` | `"wp-uploads"` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name (nonprod or production) | `string` | n/a | yes |
| <a name="input_lifecycle_cool_tier_days"></a> [lifecycle\_cool\_tier\_days](#input\_lifecycle\_cool\_tier\_days) | Days since last access before moving base blobs to Cool tier | `number` | `30` | no |
| <a name="input_lifecycle_policy_enabled"></a> [lifecycle\_policy\_enabled](#input\_lifecycle\_policy\_enabled) | Enable lifecycle management policy for blob tiering and version cleanup | `bool` | `true` | no |
| <a name="input_lifecycle_prefix_match"></a> [lifecycle\_prefix\_match](#input\_lifecycle\_prefix\_match) | List of blob prefixes to scope the lifecycle management policy | `list(string)` | <pre>["uploads/"]</pre> | no |
| <a name="input_lifecycle_snapshot_delete_days"></a> [lifecycle\_snapshot\_delete\_days](#input\_lifecycle\_snapshot\_delete\_days) | Days since creation before deleting old snapshots | `number` | `90` | no |
| <a name="input_lifecycle_version_delete_days"></a> [lifecycle\_version\_delete\_days](#input\_lifecycle\_version\_delete\_days) | Days since creation before deleting old blob versions | `number` | `90` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region for resources | `string` | n/a | yes |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name used in resource naming (lowercase, 2-24 chars) | `string` | n/a | yes |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Name of the resource group | `string` | n/a | yes |
| <a name="input_site_name"></a> [site\_name](#input\_site\_name) | Site name used for resource naming (lowercase, hyphens only) | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to all resources | `map(string)` | `{}` | no |
| <a name="input_versioning_enabled"></a> [versioning\_enabled](#input\_versioning\_enabled) | Enable blob versioning for point-in-time recovery | `bool` | `true` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_account_id"></a> [account\_id](#output\_account\_id) | ID of the Storage Account |
| <a name="output_account_name"></a> [account\_name](#output\_account\_name) | Name of the Storage Account |
| <a name="output_additional_container_names"></a> [additional\_container\_names](#output\_additional\_container\_names) | Map of additional container names created |
| <a name="output_container_name"></a> [container\_name](#output\_container\_name) | Name of the uploads container |
| <a name="output_primary_access_key"></a> [primary\_access\_key](#output\_primary\_access\_key) | Primary access key for the Storage Account |
| <a name="output_primary_blob_endpoint"></a> [primary\_blob\_endpoint](#output\_primary\_blob\_endpoint) | Primary blob endpoint URL |
| <a name="output_primary_connection_string"></a> [primary\_connection\_string](#output\_primary\_connection\_string) | Primary connection string for the Storage Account |
<!-- END_TF_DOCS -->
