# Database Module

Layer 2 Application module for MySQL Flexible Server with VNet integration.

## Overview

This module creates:
- MySQL Flexible Server with delegated subnet (no public access)
- WordPress database with UTF8MB4 charset
- Secure transport enforcement (TLS 1.2+)
- Optional high availability (Zone Redundant)
- Geo-redundant backup support

## CRITICAL: Production SKU Requirements

**Burstable SKUs (B_Standard_B*) are NOT recommended for production.**

Burstable SKUs use CPU credits that deplete under sustained WordPress load:
- Initial burst capability degrades over time
- Once credits exhaust, performance drops significantly
- Marketing site traffic during campaigns will exhaust credits

**Always use D-series SKUs (GP_Standard_D*) for production:**
- Consistent performance under sustained load
- No credit system limitations
- Recommended minimum: `GP_Standard_D2ds_v4`

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| site_name | Site name for resource naming | string | - | yes |
| environment | Environment (nonprod/production) | string | - | yes |
| location | Azure region | string | - | yes |
| resource_group_name | Resource group name | string | - | yes |
| db_subnet_id | Database subnet ID | string | - | yes |
| private_dns_zone_id | MySQL private DNS zone ID | string | - | yes |
| sku_name | MySQL SKU | string | "GP_Standard_D2ds_v4" | no |
| storage_size_gb | Storage size (20-16384) | number | 100 | no |
| backup_retention_days | Backup retention (1-35) | number | 7 | no |
| geo_redundant_backup | Enable geo-redundant backup | bool | false | no |
| high_availability_mode | HA mode (Disabled/SameZone/ZoneRedundant) | string | "Disabled" | no |
| admin_username | MySQL admin username | string | "wpadmin" | no |
| admin_password | MySQL admin password | string | - | yes |
| tags | Resource tags | map(string) | {} | no |

## Outputs

| Name | Description |
|------|-------------|
| server_id | MySQL server ID |
| server_name | MySQL server name |
| server_fqdn | MySQL server FQDN |
| database_name | WordPress database name |

## Usage

```hcl
module "database" {
  source = "../modules/layer-2-application/database"

  site_name           = "workout-tracker"
  environment         = "production"
  location            = "East US"
  resource_group_name = azurerm_resource_group.main.name

  db_subnet_id        = module.networking.db_subnet_id
  private_dns_zone_id = module.dns_zones.mysql_dns_zone_id

  sku_name               = "GP_Standard_D2ds_v4"  # D-series for production!
  storage_size_gb        = 100
  backup_retention_days  = 30
  geo_redundant_backup   = true
  high_availability_mode = "ZoneRedundant"

  admin_username = "wpadmin"
  admin_password = random_password.db.result

  tags = local.tags
}
```

## Validation Rules

The module enforces these validations at plan time:

| Variable | Rule | Error Message |
|----------|------|---------------|
| `site_name` | `^[a-z0-9-]+$` | Site name must contain only lowercase letters, numbers, and hyphens |
| `environment` | `nonprod` or `production` | Environment must be 'nonprod' or 'production' |
| `sku_name` | `^(B_Standard_B\|GP_Standard_D\|MO_Standard_E)` | SKU must be Burstable, General Purpose, or Memory Optimized |
| `storage_size_gb` | 20-16384 | Storage size must be between 20 and 16384 GB |
| `storage_iops` | 360-20000 | Storage IOPS must be between 360 and 20000 |
| `backup_retention_days` | 1-35 | Backup retention must be between 1 and 35 days |
| `high_availability_mode` | `Disabled`, `SameZone`, `ZoneRedundant` | HA mode must be one of the valid values |
| `admin_username` | Not reserved name | Admin username cannot be admin, administrator, root, sa, guest |
| `admin_password` | Length >= 8 | Admin password must be at least 8 characters |

**Production D-series Enforcement**: When `enforce_production_sku = true` (default), production environments reject Burstable SKUs.

## Security

- VNet integration (no public access)
- TLS 1.2 minimum enforced
- SSL required for all connections
- Private DNS zone for name resolution
