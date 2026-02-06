# WordPress Site Module

Complete WordPress deployment composition module that orchestrates all sub-modules.

## Overview

This module creates a complete WordPress site deployment including:
- Resource Group
- Virtual Network with subnets
- MySQL Flexible Server with private endpoint
- Azure Blob Storage for media
- Key Vault for secrets management
- App Service with managed identity
- Optional monitoring and CDN

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.6.0 |
| <a name="requirement_azapi"></a> [azapi](#requirement\_azapi) | >= 1.12.0 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | >= 4.0.0 |
| <a name="requirement_cloudflare"></a> [cloudflare](#requirement\_cloudflare) | >= 4.0.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.5.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | >= 0.9.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azapi"></a> [azapi](#provider\_azapi) | >= 1.12.0 |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | >= 4.0.0 |
| <a name="provider_random"></a> [random](#provider\_random) | >= 3.5.0 |
| <a name="provider_time"></a> [time](#provider\_time) | >= 0.9.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_app_service"></a> [app\_service](#module\_app\_service) | ../app-service | n/a |
| <a name="module_cloudflare"></a> [cloudflare](#module\_cloudflare) | ../cloudflare | n/a |
| <a name="module_database"></a> [database](#module\_database) | ../database | n/a |
| <a name="module_dns_zones"></a> [dns\_zones](#module\_dns\_zones) | ../dns-zones | n/a |
| <a name="module_front_door"></a> [front\_door](#module\_front\_door) | ../front-door | n/a |
| <a name="module_key_vault"></a> [key\_vault](#module\_key\_vault) | ../key-vault | n/a |
| <a name="module_networking"></a> [networking](#module\_networking) | ../networking | n/a |
| <a name="module_storage"></a> [storage](#module\_storage) | ../storage | n/a |

## Resources

| Name | Type |
|------|------|
| [azapi_update_resource.app_service_front_door_restriction](https://registry.terraform.io/providers/azure/azapi/latest/docs/resources/update_resource) | resource |
| [azurerm_app_service_custom_hostname_binding.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/app_service_custom_hostname_binding) | resource |
| [azurerm_application_insights.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_insights) | resource |
| [azurerm_key_vault_access_policy.app_service_update](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault_access_policy) | resource |
| [azurerm_log_analytics_workspace.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/log_analytics_workspace) | resource |
| [azurerm_management_lock.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/management_lock) | resource |
| [azurerm_monitor_action_group.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_action_group) | resource |
| [azurerm_monitor_diagnostic_setting.app_service](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_diagnostic_setting) | resource |
| [azurerm_monitor_diagnostic_setting.front_door](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_diagnostic_setting) | resource |
| [azurerm_monitor_diagnostic_setting.mysql](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_diagnostic_setting) | resource |
| [azurerm_monitor_metric_alert.high_cpu](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_metric_alert) | resource |
| [azurerm_monitor_metric_alert.http_5xx](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_metric_alert) | resource |
| [azurerm_monitor_metric_alert.response_time](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_metric_alert) | resource |
| [azurerm_resource_group.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [random_password.db](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [time_sleep.dns_propagation](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_alert_recipients"></a> [alert\_recipients](#input\_alert\_recipients) | Email addresses for alert notifications | `list(string)` | `[]` | no |
| <a name="input_app_service"></a> [app\_service](#input\_app\_service) | App Service configuration | <pre>object({<br/>    plan_id           = optional(string, null)<br/>    use_shared_plan   = optional(bool, false)<br/>    sku_name          = optional(string, "P1v3")<br/>    always_on         = optional(bool, true)<br/>    health_check_path = optional(string, "/")<br/>    worker_count      = optional(number, 1)<br/>  })</pre> | `{}` | no |
| <a name="input_cdn_provider"></a> [cdn\_provider](#input\_cdn\_provider) | CDN provider: 'cloudflare' (uses Cloudflare CDN/WAF), 'azure\_front\_door' (uses Azure Front Door), 'direct' (no CDN) | `string` | `"direct"` | no |
| <a name="input_cloudflare"></a> [cloudflare](#input\_cloudflare) | Cloudflare configuration | <pre>object({<br/>    enabled                        = optional(bool, false)<br/>    account_id                     = optional(string, "")<br/>    domain                         = optional(string, "")<br/>    subdomain                      = optional(string, "")<br/>    proxied                        = optional(bool, true)<br/>    enable_waf                     = optional(bool, false) # Default false for Free plan compatibility<br/>    enable_page_rules              = optional(bool, false) # Default false for Free plan compatibility (3 rule limit)<br/>    enable_cache_rules             = optional(bool, false) # Requires paid plan<br/>    enable_zone_setting_overrides  = optional(bool, false) # Some settings can't be modified on Free plan<br/>    enable_wordpress_optimizations = optional(bool, true)<br/>  })</pre> | `{}` | no |
| <a name="input_custom_domain"></a> [custom\_domain](#input\_custom\_domain) | Custom domain for the WordPress site | `string` | n/a | yes |
| <a name="input_database"></a> [database](#input\_database) | Database configuration | <pre>object({<br/>    sku_name               = optional(string, "GP_Standard_D2ds_v4")<br/>    storage_size_gb        = optional(number, 100)<br/>    storage_iops           = optional(number, 700)<br/>    backup_retention_days  = optional(number, 7)<br/>    geo_redundant_backup   = optional(bool, false)<br/>    high_availability_mode = optional(string, "Disabled")<br/>  })</pre> | `{}` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name (nonprod or production) | `string` | n/a | yes |
| <a name="input_front_door"></a> [front\_door](#input\_front\_door) | Front Door configuration | <pre>object({<br/>    enabled               = optional(bool, true)<br/>    sku_name              = optional(string, "Premium_AzureFrontDoor")<br/>    waf_mode              = optional(string, "Prevention")<br/>    cache_uploads_minutes = optional(number, 180)<br/>    cache_static_minutes  = optional(number, 180)<br/>  })</pre> | `{}` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region for all resources | `string` | n/a | yes |
| <a name="input_monitoring"></a> [monitoring](#input\_monitoring) | Monitoring configuration | <pre>object({<br/>    log_analytics_workspace_id = optional(string, null)<br/>    retention_days             = optional(number, 30)<br/>    alerts = optional(object({<br/>      http_5xx_threshold   = optional(number, 10)<br/>      high_cpu_threshold   = optional(number, 80)<br/>      db_failure_threshold = optional(number, 5)<br/>      alert_window_minutes = optional(number, 5)<br/>    }), {})<br/>  })</pre> | `{}` | no |
| <a name="input_networking"></a> [networking](#input\_networking) | Networking configuration | <pre>object({<br/>    vnet_address_space           = optional(string, "10.0.0.0/16")<br/>    app_subnet_cidr              = optional(string, "10.0.0.0/24")<br/>    db_subnet_cidr               = optional(string, "10.0.1.0/24")<br/>    private_endpoint_subnet_cidr = optional(string, "10.0.2.0/24")<br/>  })</pre> | `{}` | no |
| <a name="input_plan_density_limit"></a> [plan\_density\_limit](#input\_plan\_density\_limit) | Maximum sites per App Service Plan (recommended 8-10 for P1v3) | `number` | `10` | no |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name used in resource naming (lowercase, 2-24 chars) | `string` | n/a | yes |
| <a name="input_shared_plan_sku"></a> [shared\_plan\_sku](#input\_shared\_plan\_sku) | SKU of the shared App Service Plan. Required when app\_service.use\_shared\_plan = true to determine feature availability. | `string` | `null` | no |
| <a name="input_shared_resource_group_name"></a> [shared\_resource\_group\_name](#input\_shared\_resource\_group\_name) | Name of the shared resource group where the shared App Service Plan is located. Required when app\_service.use\_shared\_plan = true. | `string` | `null` | no |
| <a name="input_site_name"></a> [site\_name](#input\_site\_name) | Site name used for resource naming (lowercase, hyphens only) | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to all resources | `map(string)` | `{}` | no |
| <a name="input_tenant_id"></a> [tenant\_id](#input\_tenant\_id) | Azure AD tenant ID | `string` | n/a | yes |
| <a name="input_wordpress_version"></a> [wordpress\_version](#input\_wordpress\_version) | WordPress Docker image tag (PHP version) | `string` | `"8.4"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_app_insights_id"></a> [app\_insights\_id](#output\_app\_insights\_id) | Application Insights ID |
| <a name="output_app_insights_name"></a> [app\_insights\_name](#output\_app\_insights\_name) | Application Insights name |
| <a name="output_app_service_default_hostname"></a> [app\_service\_default\_hostname](#output\_app\_service\_default\_hostname) | Web App default hostname |
| <a name="output_app_service_id"></a> [app\_service\_id](#output\_app\_service\_id) | Web App ID |
| <a name="output_app_service_name"></a> [app\_service\_name](#output\_app\_service\_name) | Web App name |
| <a name="output_app_service_plan_id"></a> [app\_service\_plan\_id](#output\_app\_service\_plan\_id) | App Service Plan ID |
| <a name="output_cdn_provider"></a> [cdn\_provider](#output\_cdn\_provider) | Active CDN provider |
| <a name="output_cloudflare_dns_hostname"></a> [cloudflare\_dns\_hostname](#output\_cloudflare\_dns\_hostname) | DNS hostname managed by Cloudflare |
| <a name="output_cloudflare_nameservers"></a> [cloudflare\_nameservers](#output\_cloudflare\_nameservers) | Cloudflare nameservers for this zone |
| <a name="output_cloudflare_proxied"></a> [cloudflare\_proxied](#output\_cloudflare\_proxied) | Whether Cloudflare proxy (CDN) is active |
| <a name="output_cloudflare_zone_id"></a> [cloudflare\_zone\_id](#output\_cloudflare\_zone\_id) | Cloudflare zone ID (when cdn\_provider = cloudflare) |
| <a name="output_custom_domain_validation_token"></a> [custom\_domain\_validation\_token](#output\_custom\_domain\_validation\_token) | TXT record value for custom domain validation |
| <a name="output_database_name"></a> [database\_name](#output\_database\_name) | WordPress database name |
| <a name="output_database_server_fqdn"></a> [database\_server\_fqdn](#output\_database\_server\_fqdn) | MySQL server FQDN |
| <a name="output_database_server_id"></a> [database\_server\_id](#output\_database\_server\_id) | MySQL server ID |
| <a name="output_front_door_endpoint_hostname"></a> [front\_door\_endpoint\_hostname](#output\_front\_door\_endpoint\_hostname) | Front Door endpoint hostname (for DNS CNAME) |
| <a name="output_front_door_profile_id"></a> [front\_door\_profile\_id](#output\_front\_door\_profile\_id) | Front Door profile ID |
| <a name="output_front_door_resource_guid"></a> [front\_door\_resource\_guid](#output\_front\_door\_resource\_guid) | Front Door profile resource GUID (for App Service IP restriction) |
| <a name="output_key_vault_id"></a> [key\_vault\_id](#output\_key\_vault\_id) | Key Vault ID |
| <a name="output_key_vault_uri"></a> [key\_vault\_uri](#output\_key\_vault\_uri) | Key Vault URI |
| <a name="output_log_analytics_workspace_id"></a> [log\_analytics\_workspace\_id](#output\_log\_analytics\_workspace\_id) | Log Analytics Workspace ID |
| <a name="output_resource_group_id"></a> [resource\_group\_id](#output\_resource\_group\_id) | ID of the resource group |
| <a name="output_resource_group_name"></a> [resource\_group\_name](#output\_resource\_group\_name) | Name of the resource group |
| <a name="output_site_name"></a> [site\_name](#output\_site\_name) | The site name |
| <a name="output_staging_slot_hostname"></a> [staging\_slot\_hostname](#output\_staging\_slot\_hostname) | Staging slot hostname |
| <a name="output_storage_account_name"></a> [storage\_account\_name](#output\_storage\_account\_name) | Storage Account name |
| <a name="output_storage_blob_endpoint"></a> [storage\_blob\_endpoint](#output\_storage\_blob\_endpoint) | Storage blob endpoint |
| <a name="output_vnet_id"></a> [vnet\_id](#output\_vnet\_id) | Virtual Network ID |
| <a name="output_vnet_name"></a> [vnet\_name](#output\_vnet\_name) | Virtual Network name |
| <a name="output_wordpress_admin_url"></a> [wordpress\_admin\_url](#output\_wordpress\_admin\_url) | WordPress admin URL |
| <a name="output_wordpress_url"></a> [wordpress\_url](#output\_wordpress\_url) | WordPress site URL |
<!-- END_TF_DOCS -->
