# Key Vault Module

Layer 2 Application module for secrets management with managed identity access.

## Overview

This module creates:
- Azure Key Vault for site-specific secrets
- Access policy for App Service managed identity
- Access policy for Terraform deployment principal
- Soft-delete and purge protection

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| site_name | Site name for resource naming | string | - | yes |
| environment | Environment (nonprod/production) | string | - | yes |
| location | Azure region | string | - | yes |
| resource_group_name | Resource group name | string | - | yes |
| tenant_id | Azure AD tenant ID | string | - | yes |
| app_service_principal_id | App Service managed identity principal ID | string | - | yes |
| secrets | Map of secrets to store | map(string) | {} | no |
| soft_delete_retention_days | Soft-delete retention (7-90) | number | 90 | no |
| purge_protection_enabled | Enable purge protection | bool | true | no |
| tags | Resource tags | map(string) | {} | no |

## Outputs

| Name | Description |
|------|-------------|
| id | Key Vault ID |
| name | Key Vault name |
| uri | Key Vault URI |
| secret_uris | Map of secret names to versioned URIs |
| secret_versionless_uris | Map of secret names to versionless URIs |

## Usage

```hcl
module "key_vault" {
  source = "../modules/layer-2-application/key-vault"

  site_name           = "workout-tracker"
  environment         = "nonprod"
  location            = "East US"
  resource_group_name = azurerm_resource_group.main.name
  tenant_id           = data.azurerm_client_config.current.tenant_id

  app_service_principal_id = module.app_service.principal_id

  secrets = {
    "db-password"       = random_password.db.result
    "storage-key"       = module.storage.primary_access_key
    "appinsights-conn"  = module.monitoring.connection_string
  }

  tags = local.tags
}
```

## App Service Integration

Use versionless URIs for App Service Key Vault references:

```hcl
app_settings = {
  "DB_PASSWORD" = "@Microsoft.KeyVault(SecretUri=${module.key_vault.secret_versionless_uris["db-password"]})"
}
```

## Validation Rules

The module enforces these validations at plan time:

| Variable | Rule | Error Message |
|----------|------|---------------|
| `site_name` | `^[a-z0-9-]+$` | Site name must contain only lowercase letters, numbers, and hyphens |
| `environment` | `nonprod` or `production` | Environment must be 'nonprod' or 'production' |
| `soft_delete_retention_days` | 7-90 | Soft delete retention must be between 7 and 90 days |

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
| [azurerm_key_vault.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault) | resource |
| [azurerm_key_vault_access_policy.app_service](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault_access_policy) | resource |
| [azurerm_key_vault_access_policy.terraform](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault_access_policy) | resource |
| [azurerm_key_vault_secret.secrets](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault_secret) | resource |
| [azurerm_client_config.current](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/client_config) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_app_service_principal_id"></a> [app\_service\_principal\_id](#input\_app\_service\_principal\_id) | Principal ID of the App Service managed identity | `string` | n/a | yes |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name (nonprod or production) | `string` | n/a | yes |
| <a name="input_location"></a> [location](#input\_location) | Azure region for resources | `string` | n/a | yes |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name used in resource naming (lowercase, 2-24 chars) | `string` | n/a | yes |
| <a name="input_public_network_access_enabled"></a> [public\_network\_access\_enabled](#input\_public\_network\_access\_enabled) | Allow public network access (required for CI/CD deployment) | `bool` | `true` | no |
| <a name="input_purge_protection_enabled"></a> [purge\_protection\_enabled](#input\_purge\_protection\_enabled) | Enable purge protection (recommended for production) | `bool` | `true` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Name of the resource group | `string` | n/a | yes |
| <a name="input_secrets"></a> [secrets](#input\_secrets) | Map of secrets to store in Key Vault | `map(string)` | `{}` | no |
| <a name="input_site_name"></a> [site\_name](#input\_site\_name) | Site name used for resource naming (lowercase, hyphens only) | `string` | n/a | yes |
| <a name="input_soft_delete_retention_days"></a> [soft\_delete\_retention\_days](#input\_soft\_delete\_retention\_days) | Days to retain soft-deleted secrets (7-90) | `number` | `90` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to all resources | `map(string)` | `{}` | no |
| <a name="input_tenant_id"></a> [tenant\_id](#input\_tenant\_id) | Azure AD tenant ID | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_id"></a> [id](#output\_id) | ID of the Key Vault |
| <a name="output_name"></a> [name](#output\_name) | Name of the Key Vault |
| <a name="output_secret_uris"></a> [secret\_uris](#output\_secret\_uris) | Map of secret names to their versioned URIs |
| <a name="output_secret_versionless_uris"></a> [secret\_versionless\_uris](#output\_secret\_versionless\_uris) | Map of secret names to their versionless URIs (for App Service Key Vault references) |
| <a name="output_uri"></a> [uri](#output\_uri) | URI of the Key Vault |
<!-- END_TF_DOCS -->
