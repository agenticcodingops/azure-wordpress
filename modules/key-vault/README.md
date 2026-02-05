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
