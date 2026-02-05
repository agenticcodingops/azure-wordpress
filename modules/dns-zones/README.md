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
