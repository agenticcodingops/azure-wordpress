# Monitoring Module

Layer 2 Application module for Application Insights, Log Analytics, and Alerts.

## Overview

This module creates:
- Application Insights instance
- Log Analytics Workspace (optional, can use shared)
- Diagnostic settings for App Service, MySQL, Front Door
- Alert rules with action groups

## Log Analytics Workspace

Per environment, a shared Log Analytics Workspace centralizes logs:
- App Service HTTP/console/app logs
- MySQL slow query and audit logs
- Front Door access and WAF logs

Retention:
- Nonprod: 30 days
- Production: 90 days (enforced minimum)

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| site_name | Site name | string | - | yes |
| environment | Environment | string | - | yes |
| location | Azure region | string | - | yes |
| resource_group_name | Resource group | string | - | yes |
| log_analytics_workspace_id | Existing workspace ID | string | null | no |
| retention_days | Log retention (30-730) | number | 30 | no |
| app_service_id | App Service ID to monitor | string | - | yes |
| mysql_server_id | MySQL server ID | string | "" | no |
| front_door_profile_id | Front Door profile ID | string | "" | no |
| alert_recipients | Email addresses for alerts | list(string) | [] | no |
| alert_rules | Alert thresholds | object | {} | no |
| tags | Resource tags | map(string) | {} | no |

## Outputs

| Name | Description |
|------|-------------|
| app_insights_id | Application Insights ID |
| instrumentation_key | App Insights instrumentation key |
| connection_string | App Insights connection string |
| log_analytics_workspace_id | Log Analytics Workspace ID |

## Alert Rules

Default alert thresholds:
- HTTP 5xx errors: > 10 in 5 minutes
- High CPU: > 80% for 5 minutes
- Response time: > 3 seconds (per performance goal)

## Usage

```hcl
module "monitoring" {
  source = "../modules/layer-2-application/monitoring"

  site_name           = "workout-tracker"
  environment         = "nonprod"
  location            = "East US"
  resource_group_name = azurerm_resource_group.main.name

  app_service_id        = module.app_service.id
  mysql_server_id       = module.database.server_id
  front_door_profile_id = module.front_door.profile_id

  alert_recipients = ["devops@trackroutinely.com"]

  alert_rules = {
    http_5xx_threshold   = 10
    high_cpu_threshold   = 80
    alert_window_minutes = 5
  }

  tags = local.tags
}
```

## Validation Rules

The module enforces these validations at plan time:

| Variable | Rule | Error Message |
|----------|------|---------------|
| `site_name` | `^[a-z0-9-]+$` | Site name must contain only lowercase letters, numbers, and hyphens |
| `environment` | `nonprod` or `production` | Environment must be 'nonprod' or 'production' |
| `retention_days` | 30-730 | Retention must be between 30 and 730 days |

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
| [azurerm_application_insights.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_insights) | resource |
| [azurerm_log_analytics_workspace.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/log_analytics_workspace) | resource |
| [azurerm_monitor_action_group.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_action_group) | resource |
| [azurerm_monitor_diagnostic_setting.app_service](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_diagnostic_setting) | resource |
| [azurerm_monitor_diagnostic_setting.front_door](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_diagnostic_setting) | resource |
| [azurerm_monitor_diagnostic_setting.mysql](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_diagnostic_setting) | resource |
| [azurerm_monitor_metric_alert.high_cpu](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_metric_alert) | resource |
| [azurerm_monitor_metric_alert.http_5xx](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_metric_alert) | resource |
| [azurerm_monitor_metric_alert.response_time](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_metric_alert) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_alert_recipients"></a> [alert\_recipients](#input\_alert\_recipients) | Email addresses for alert notifications | `list(string)` | `[]` | no |
| <a name="input_alert_rules"></a> [alert\_rules](#input\_alert\_rules) | Alert threshold configuration | <pre>object({<br/>    http_5xx_threshold   = optional(number, 10)<br/>    high_cpu_threshold   = optional(number, 80)<br/>    db_failure_threshold = optional(number, 5)<br/>    alert_window_minutes = optional(number, 5)<br/>  })</pre> | `{}` | no |
| <a name="input_app_service_id"></a> [app\_service\_id](#input\_app\_service\_id) | ID of the App Service to monitor | `string` | n/a | yes |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name (nonprod or production) | `string` | n/a | yes |
| <a name="input_front_door_profile_id"></a> [front\_door\_profile\_id](#input\_front\_door\_profile\_id) | ID of the Front Door profile to monitor | `string` | `""` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region for resources | `string` | n/a | yes |
| <a name="input_log_analytics_workspace_id"></a> [log\_analytics\_workspace\_id](#input\_log\_analytics\_workspace\_id) | ID of existing Log Analytics Workspace. If null, a new workspace is created. | `string` | `null` | no |
| <a name="input_mysql_server_id"></a> [mysql\_server\_id](#input\_mysql\_server\_id) | ID of the MySQL server to monitor | `string` | `""` | no |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name used in resource naming (lowercase, 2-24 chars) | `string` | n/a | yes |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Name of the resource group | `string` | n/a | yes |
| <a name="input_retention_days"></a> [retention\_days](#input\_retention\_days) | Log retention in days (30 nonprod, 90 production recommended) | `number` | `30` | no |
| <a name="input_site_name"></a> [site\_name](#input\_site\_name) | Site name used for resource naming (lowercase, hyphens only) | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to all resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_action_group_id"></a> [action\_group\_id](#output\_action\_group\_id) | ID of the alert action group |
| <a name="output_app_insights_id"></a> [app\_insights\_id](#output\_app\_insights\_id) | ID of the Application Insights instance |
| <a name="output_app_insights_name"></a> [app\_insights\_name](#output\_app\_insights\_name) | Name of the Application Insights instance |
| <a name="output_connection_string"></a> [connection\_string](#output\_connection\_string) | Connection string for Application Insights |
| <a name="output_instrumentation_key"></a> [instrumentation\_key](#output\_instrumentation\_key) | Instrumentation key for Application Insights |
| <a name="output_log_analytics_workspace_id"></a> [log\_analytics\_workspace\_id](#output\_log\_analytics\_workspace\_id) | ID of the Log Analytics Workspace |
| <a name="output_log_analytics_workspace_name"></a> [log\_analytics\_workspace\_name](#output\_log\_analytics\_workspace\_name) | Name of the Log Analytics Workspace |
<!-- END_TF_DOCS -->
