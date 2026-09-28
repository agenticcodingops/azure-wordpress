# Database Module

Layer 2 Application module for MySQL Flexible Server with VNet integration.

## Overview

This module creates:
- MySQL Flexible Server with delegated subnet (no public access)
- WordPress database with UTF8MB4 charset
- Secure transport enforcement (TLS 1.2+)
- Optional high availability (Zone Redundant)
- Geo-redundant backup support
- Optional slow query log (`slow_query_log_enabled`)

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
| slow_query_log_enabled | Set slow_query_log = ON and long_query_time | bool | false | no |
| long_query_time | Slow-query threshold in seconds (0-31536000) | number | 2 | no |

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

## Slow query log

Off by default. `slow_query_log_enabled = true` manages two server parameters: `slow_query_log = ON` and
`long_query_time` (default 2 seconds; the server's own default is 10). Both are dynamic, so the server does
not restart, but a new `long_query_time` applies to new connections only.

- The rows go to whatever diagnostic setting ships the `MySqlSlowLogs` category. The `wordpress-site`
  composition has always enabled that category, so they land in its workspace, in `AzureDiagnostics` with
  `Category == "MySqlSlowLogs"`. Ingestion is billed.
- Setting it back to `false` deletes both configuration resources, which resets each parameter to its server
  default (`OFF`, 10 seconds). A value set outside Terraform before you opted in is not restored.
- The accepted `long_query_time` range is MySQL's (0-31536000). Azure's own `allowedValues` for the
  parameter, and whether it reads back `"2"` unchanged, are not yet confirmed; check a nonprod plan after the
  first apply.
- Audit logging (`audit_log_enabled`) is not offered.

## Security

- VNet integration (no public access)
- TLS 1.2 minimum enforced
- SSL required for all connections
- Private DNS zone for name resolution

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.6.0 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 5.6 |
| <a name="requirement_null"></a> [null](#requirement\_null) | >= 3.2.0, < 4.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | ~> 5.6 |
| <a name="provider_null"></a> [null](#provider\_null) | >= 3.2.0, < 4.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [azurerm_mysql_flexible_database.wordpress](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/mysql_flexible_database) | resource |
| [azurerm_mysql_flexible_server.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/mysql_flexible_server) | resource |
| [azurerm_mysql_flexible_server_configuration.long_query_time](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/mysql_flexible_server_configuration) | resource |
| [azurerm_mysql_flexible_server_configuration.require_secure_transport](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/mysql_flexible_server_configuration) | resource |
| [azurerm_mysql_flexible_server_configuration.slow_query_log](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/mysql_flexible_server_configuration) | resource |
| [null_resource.validate_production_sku](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_admin_password"></a> [admin\_password](#input\_admin\_password) | MySQL admin password (store in Key Vault) | `string` | n/a | yes |
| <a name="input_admin_username"></a> [admin\_username](#input\_admin\_username) | MySQL admin username | `string` | `"wpadmin"` | no |
| <a name="input_backup_retention_days"></a> [backup\_retention\_days](#input\_backup\_retention\_days) | Backup retention in days (1-35) | `number` | `7` | no |
| <a name="input_db_subnet_id"></a> [db\_subnet\_id](#input\_db\_subnet\_id) | ID of the database subnet (from networking module) | `string` | n/a | yes |
| <a name="input_enforce_production_sku"></a> [enforce\_production\_sku](#input\_enforce\_production\_sku) | Enforce D-series SKU for production (fails if Burstable in prod) | `bool` | `true` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name (nonprod or production) | `string` | n/a | yes |
| <a name="input_geo_redundant_backup"></a> [geo\_redundant\_backup](#input\_geo\_redundant\_backup) | Enable geo-redundant backup (recommended for production). FORCES REPLACEMENT: azurerm can only set this at creation, so changing it on an existing server destroys and recreates it. Choose at creation time. | `bool` | `false` | no |
| <a name="input_high_availability_mode"></a> [high\_availability\_mode](#input\_high\_availability\_mode) | High availability mode: Disabled, SameZone, or ZoneRedundant | `string` | `"Disabled"` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region for resources | `string` | n/a | yes |
| <a name="input_long_query_time"></a> [long\_query\_time](#input\_long\_query\_time) | Seconds a statement must run to be logged as slow (the long\_query\_time server parameter). Applied only when slow\_query\_log\_enabled is true. Defaults to 2, a WordPress-oriented value; the server's own default is 10. Fractions are allowed; 0 logs every statement. A change applies to new connections only. | `number` | `2` | no |
| <a name="input_mysql_version"></a> [mysql\_version](#input\_mysql\_version) | MySQL Flexible Server version. The default, 8.0.21, is the version every existing server was created with, so leaving it unset changes nothing. Changing it on an existing server is a major-version upgrade that cannot be undone: plan and rehearse it first (agenticcodingops/trackroutinely#104, WP-43, is where that upgrade is planned). Whether azurerm performs the change in place or forces replacement depends on the provider version, so read the provider documentation for your version and dry-run first. This input only enables the change. | `string` | `"8.0.21"` | no |
| <a name="input_private_dns_zone_id"></a> [private\_dns\_zone\_id](#input\_private\_dns\_zone\_id) | ID of the MySQL private DNS zone (from dns-zones module) | `string` | n/a | yes |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name used in resource naming (lowercase, 2-24 chars) | `string` | n/a | yes |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Name of the resource group | `string` | n/a | yes |
| <a name="input_site_name"></a> [site\_name](#input\_site\_name) | Site name used for resource naming (lowercase, hyphens only) | `string` | n/a | yes |
| <a name="input_sku_name"></a> [sku\_name](#input\_sku\_name) | MySQL SKU name. Use GP\_Standard\_D2ds\_v4 or higher for production (D-series REQUIRED). | `string` | `"GP_Standard_D2ds_v4"` | no |
| <a name="input_slow_query_log_enabled"></a> [slow\_query\_log\_enabled](#input\_slow\_query\_log\_enabled) | Set the slow\_query\_log server parameter to ON, and long\_query\_time with it, so the MySqlSlowLogs diagnostic category carries rows. Off (the default) leaves both parameters unmanaged. Turning it off again deletes the two configuration resources, which resets both parameters to their server defaults (OFF and 10 seconds). | `bool` | `false` | no |
| <a name="input_storage_auto_grow_enabled"></a> [storage\_auto\_grow\_enabled](#input\_storage\_auto\_grow\_enabled) | Enable auto-grow for MySQL storage when capacity is low | `bool` | `true` | no |
| <a name="input_storage_iops"></a> [storage\_iops](#input\_storage\_iops) | Storage IOPS (360-20000) | `number` | `700` | no |
| <a name="input_storage_size_gb"></a> [storage\_size\_gb](#input\_storage\_size\_gb) | Storage size in GB (20-16384) | `number` | `100` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to all resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_admin_username"></a> [admin\_username](#output\_admin\_username) | MySQL admin username |
| <a name="output_database_name"></a> [database\_name](#output\_database\_name) | Name of the WordPress database |
| <a name="output_server_fqdn"></a> [server\_fqdn](#output\_server\_fqdn) | FQDN of the MySQL Flexible Server |
| <a name="output_server_id"></a> [server\_id](#output\_server\_id) | ID of the MySQL Flexible Server |
| <a name="output_server_name"></a> [server\_name](#output\_server\_name) | Name of the MySQL Flexible Server |
<!-- END_TF_DOCS -->
