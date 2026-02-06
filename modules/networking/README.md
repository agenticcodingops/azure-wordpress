# Networking Module

Layer 1 Foundation module for creating isolated networking infrastructure per WordPress site.

## Overview

This module creates:
- Virtual Network (VNet) with site-specific address space
- App Service integration subnet (delegated to Microsoft.Web/serverFarms)
- Database subnet (delegated to Microsoft.DBforMySQL/flexibleServers)
- Private Endpoint subnet for Storage/Key Vault
- Network Security Groups (NSGs) with least-privilege rules

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Virtual Network                       │
│                    (10.0.0.0/16)                        │
│                                                         │
│  ┌─────────────────┐  ┌─────────────────┐              │
│  │   App Subnet    │  │    DB Subnet    │              │
│  │  (10.0.0.0/24)  │  │  (10.0.1.0/24)  │              │
│  │                 │  │                 │              │
│  │  App Service    │─▶│  MySQL Server   │              │
│  │  VNet Int.      │  │  (delegated)    │              │
│  │  (delegated)    │  │                 │              │
│  └─────────────────┘  └─────────────────┘              │
│                                                         │
│  ┌─────────────────┐                                   │
│  │   PE Subnet     │                                   │
│  │  (10.0.2.0/24)  │                                   │
│  │                 │                                   │
│  │  Private        │                                   │
│  │  Endpoints      │                                   │
│  └─────────────────┘                                   │
└─────────────────────────────────────────────────────────┘
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| site_name | Site name for resource naming | string | - | yes |
| environment | Environment (nonprod/production) | string | - | yes |
| location | Azure region | string | - | yes |
| resource_group_name | Resource group name | string | - | yes |
| vnet_address_space | VNet CIDR block | string | "10.0.0.0/16" | no |
| app_subnet_cidr | App subnet CIDR | string | "10.0.0.0/24" | no |
| db_subnet_cidr | Database subnet CIDR | string | "10.0.1.0/24" | no |
| private_endpoint_subnet_cidr | PE subnet CIDR | string | "10.0.2.0/24" | no |
| tags | Resource tags | map(string) | {} | no |

## Outputs

| Name | Description |
|------|-------------|
| vnet_id | Virtual Network ID |
| vnet_name | Virtual Network name |
| app_subnet_id | App Service subnet ID |
| db_subnet_id | Database subnet ID |
| private_endpoint_subnet_id | Private Endpoint subnet ID |

## Usage

```hcl
module "networking" {
  source = "../modules/layer-1-foundation/networking"

  site_name           = "workout-tracker"
  environment         = "nonprod"
  location            = "East US"
  resource_group_name = azurerm_resource_group.main.name

  tags = {
    Environment = "nonprod"
    ManagedBy   = "terraform"
  }
}
```

## Security

- NSGs implement least-privilege access
- App subnet only allows HTTPS from Azure Front Door
- Database subnet only allows MySQL (3306) from App subnet
- All other inbound traffic is denied

## Validation Rules

The module enforces these validations at plan time:

| Variable | Rule | Error Message |
|----------|------|---------------|
| `site_name` | `^[a-z0-9-]+$` | Site name must contain only lowercase letters, numbers, and hyphens |
| `environment` | `nonprod` or `production` | Environment must be 'nonprod' or 'production' |
| `vnet_address_space` | Valid CIDR block | VNet address space must be a valid CIDR block |
| `app_subnet_cidr` | Valid CIDR block | App subnet CIDR must be a valid CIDR block |
| `db_subnet_cidr` | Valid CIDR block | Database subnet CIDR must be a valid CIDR block |
| `private_endpoint_subnet_cidr` | Valid CIDR block | Private endpoint subnet CIDR must be a valid CIDR block |

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
| [azurerm_network_security_group.app](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_group) | resource |
| [azurerm_network_security_group.db](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_group) | resource |
| [azurerm_subnet.app](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.db](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.private_endpoints](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet_network_security_group_association.app](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet_network_security_group_association) | resource |
| [azurerm_subnet_network_security_group_association.db](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet_network_security_group_association) | resource |
| [azurerm_virtual_network.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_app_subnet_cidr"></a> [app\_subnet\_cidr](#input\_app\_subnet\_cidr) | CIDR block for the App Service subnet (VNet integration) | `string` | `"10.0.0.0/24"` | no |
| <a name="input_db_subnet_cidr"></a> [db\_subnet\_cidr](#input\_db\_subnet\_cidr) | CIDR block for the database subnet (MySQL Private Endpoint) | `string` | `"10.0.1.0/24"` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name (nonprod or production) | `string` | n/a | yes |
| <a name="input_location"></a> [location](#input\_location) | Azure region for resources | `string` | n/a | yes |
| <a name="input_private_endpoint_subnet_cidr"></a> [private\_endpoint\_subnet\_cidr](#input\_private\_endpoint\_subnet\_cidr) | CIDR block for private endpoints (Storage, Key Vault) | `string` | `"10.0.2.0/24"` | no |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name used in resource naming (lowercase, 2-24 chars) | `string` | n/a | yes |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Name of the resource group | `string` | n/a | yes |
| <a name="input_site_name"></a> [site\_name](#input\_site\_name) | Site name used for resource naming (lowercase, hyphens only) | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to all resources | `map(string)` | `{}` | no |
| <a name="input_vnet_address_space"></a> [vnet\_address\_space](#input\_vnet\_address\_space) | Address space for the VNet in CIDR notation | `string` | `"10.0.0.0/16"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_app_subnet_id"></a> [app\_subnet\_id](#output\_app\_subnet\_id) | ID of the App Service integration subnet |
| <a name="output_app_subnet_name"></a> [app\_subnet\_name](#output\_app\_subnet\_name) | Name of the App Service integration subnet |
| <a name="output_db_subnet_id"></a> [db\_subnet\_id](#output\_db\_subnet\_id) | ID of the database (MySQL) subnet |
| <a name="output_db_subnet_name"></a> [db\_subnet\_name](#output\_db\_subnet\_name) | Name of the database subnet |
| <a name="output_private_endpoint_subnet_id"></a> [private\_endpoint\_subnet\_id](#output\_private\_endpoint\_subnet\_id) | ID of the private endpoint subnet |
| <a name="output_private_endpoint_subnet_name"></a> [private\_endpoint\_subnet\_name](#output\_private\_endpoint\_subnet\_name) | Name of the private endpoint subnet |
| <a name="output_vnet_id"></a> [vnet\_id](#output\_vnet\_id) | ID of the Virtual Network |
| <a name="output_vnet_name"></a> [vnet\_name](#output\_vnet\_name) | Name of the Virtual Network |
<!-- END_TF_DOCS -->
