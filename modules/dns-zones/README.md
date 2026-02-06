# DNS Zones Module

Layer 1 Foundation module for creating Private DNS zones for MySQL Flexible Server.

## Overview

This module creates:
- Private DNS Zone for MySQL Flexible Server (`privatelink.mysql.database.azure.com`)
- VNet link to enable name resolution within the Virtual Network

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Private DNS Zone                      │
│           privatelink.mysql.database.azure.com          │
│                                                         │
│  ┌─────────────────┐                                   │
│  │   VNet Link     │                                   │
│  │                 │                                   │
│  │  Enables DNS    │                                   │
│  │  resolution     │                                   │
│  │  for MySQL      │                                   │
│  │  FQDN within    │                                   │
│  │  the VNet       │                                   │
│  └─────────────────┘                                   │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

## Why Private DNS?

MySQL Flexible Server with VNet integration requires Private DNS zones to:
1. Resolve the server FQDN from within the VNet
2. Enable secure connectivity without public endpoints
3. Prevent dependency cycles with Private Endpoints

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| site_name | Site name for resource naming | string | - | yes |
| resource_group_name | Resource group name | string | - | yes |
| vnet_id | VNet ID to link the DNS zone | string | - | yes |
| tags | Resource tags | map(string) | {} | no |

## Outputs

| Name | Description |
|------|-------------|
| mysql_dns_zone_id | Private DNS Zone ID |
| mysql_dns_zone_name | Private DNS Zone name |
| mysql_dns_zone_link_id | VNet link ID |

## Usage

```hcl
module "dns_zones" {
  source = "../modules/layer-1-foundation/dns-zones"

  site_name           = "workout-tracker"
  resource_group_name = azurerm_resource_group.main.name
  vnet_id             = module.networking.vnet_id

  tags = {
    Environment = "nonprod"
    ManagedBy   = "terraform"
  }
}
```

## Dependencies

This module requires:
- Networking module outputs (vnet_id)

This module is required by:
- Database module (private_dns_zone_id)

## Validation Rules

The module enforces these validations at plan time:

| Variable | Rule | Error Message |
|----------|------|---------------|
| `site_name` | `^[a-z0-9-]+$` | Site name must contain only lowercase letters, numbers, and hyphens |

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
| [azurerm_private_dns_zone.mysql](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone) | resource |
| [azurerm_private_dns_zone_virtual_network_link.mysql](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone_virtual_network_link) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name used in resource naming (lowercase, 2-24 chars) | `string` | n/a | yes |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Name of the resource group | `string` | n/a | yes |
| <a name="input_site_name"></a> [site\_name](#input\_site\_name) | Site name used for resource naming (lowercase, hyphens only) | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to all resources | `map(string)` | `{}` | no |
| <a name="input_vnet_id"></a> [vnet\_id](#input\_vnet\_id) | ID of the VNet to link the private DNS zone | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_mysql_dns_zone_id"></a> [mysql\_dns\_zone\_id](#output\_mysql\_dns\_zone\_id) | ID of the MySQL private DNS zone |
| <a name="output_mysql_dns_zone_link_id"></a> [mysql\_dns\_zone\_link\_id](#output\_mysql\_dns\_zone\_link\_id) | ID of the VNet link to MySQL DNS zone |
| <a name="output_mysql_dns_zone_name"></a> [mysql\_dns\_zone\_name](#output\_mysql\_dns\_zone\_name) | Name of the MySQL private DNS zone |
<!-- END_TF_DOCS -->
