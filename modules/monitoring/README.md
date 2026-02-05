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
