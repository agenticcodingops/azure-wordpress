# Monitoring Module - Layer 2 Application
# Creates Application Insights, Log Analytics Workspace, and Alert Rules

locals {
  # Short environment suffix for naming
  env_suffix = var.environment == "nonprod" ? "np" : "prod"

  # Resource naming
  name_prefix = "${var.project_name}-${var.site_name}-${local.env_suffix}"

  # Create workspace if not provided
  create_workspace = var.log_analytics_workspace_id == null
  workspace_id     = local.create_workspace ? azurerm_log_analytics_workspace.main[0].id : var.log_analytics_workspace_id

  # Retention based on environment
  retention = var.environment == "production" ? max(var.retention_days, 90) : var.retention_days

  # Alert rules with defaults
  alert_config = {
    http_5xx_threshold   = coalesce(try(var.alert_rules.http_5xx_threshold, null), 10)
    high_cpu_threshold   = coalesce(try(var.alert_rules.high_cpu_threshold, null), 80)
    db_failure_threshold = coalesce(try(var.alert_rules.db_failure_threshold, null), 5)
    alert_window_minutes = coalesce(try(var.alert_rules.alert_window_minutes, null), 5)
  }
}

# Log Analytics Workspace (shared per environment)
resource "azurerm_log_analytics_workspace" "main" {
  count = local.create_workspace ? 1 : 0

  name                = "log-${local.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = local.retention

  tags = merge(var.tags, {
    Site = var.site_name
  })
}

# Application Insights
resource "azurerm_application_insights" "main" {
  name                = "appi-${local.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  workspace_id        = local.workspace_id
  application_type    = "web"
  retention_in_days   = local.retention

  tags = merge(var.tags, {
    Site = var.site_name
  })
}

# Diagnostic Settings for App Service
resource "azurerm_monitor_diagnostic_setting" "app_service" {
  name                       = "diag-appservice-${var.site_name}"
  target_resource_id         = var.app_service_id
  log_analytics_workspace_id = local.workspace_id

  # App Service logs
  enabled_log {
    category = "AppServiceHTTPLogs"
  }

  enabled_log {
    category = "AppServiceConsoleLogs"
  }

  enabled_log {
    category = "AppServiceAppLogs"
  }

  enabled_log {
    category = "AppServicePlatformLogs"
  }

  # Metrics
  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# Diagnostic Settings for MySQL (if provided)
resource "azurerm_monitor_diagnostic_setting" "mysql" {
  count = var.mysql_server_id != "" ? 1 : 0

  name                       = "diag-mysql-${var.site_name}"
  target_resource_id         = var.mysql_server_id
  log_analytics_workspace_id = local.workspace_id

  # MySQL logs
  enabled_log {
    category = "MySqlSlowLogs"
  }

  enabled_log {
    category = "MySqlAuditLogs"
  }

  # Metrics
  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# Diagnostic Settings for Front Door (if provided)
resource "azurerm_monitor_diagnostic_setting" "front_door" {
  count = var.front_door_profile_id != "" ? 1 : 0

  name                       = "diag-frontdoor-${var.site_name}"
  target_resource_id         = var.front_door_profile_id
  log_analytics_workspace_id = local.workspace_id

  # Front Door logs
  enabled_log {
    category = "FrontDoorAccessLog"
  }

  enabled_log {
    category = "FrontDoorHealthProbeLog"
  }

  enabled_log {
    category = "FrontDoorWebApplicationFirewallLog"
  }

  # Metrics
  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# Action Group for alerts
resource "azurerm_monitor_action_group" "main" {
  count = length(var.alert_recipients) > 0 ? 1 : 0

  name                = "ag-${local.name_prefix}"
  resource_group_name = var.resource_group_name
  short_name          = substr(var.site_name, 0, 12)

  dynamic "email_receiver" {
    for_each = var.alert_recipients
    content {
      name          = "email-${email_receiver.key}"
      email_address = email_receiver.value
    }
  }

  tags = merge(var.tags, {
    Site = var.site_name
  })
}

# Alert: HTTP 5xx Errors
resource "azurerm_monitor_metric_alert" "http_5xx" {
  count = length(var.alert_recipients) > 0 ? 1 : 0

  name                = "alert-http5xx-${local.name_prefix}"
  resource_group_name = var.resource_group_name
  scopes              = [var.app_service_id]
  description         = "Alert when HTTP 5xx errors exceed threshold"
  severity            = 2 # Warning
  frequency           = "PT1M"
  window_size         = "PT${local.alert_config.alert_window_minutes}M"

  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = "Http5xx"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = local.alert_config.http_5xx_threshold
  }

  action {
    action_group_id = azurerm_monitor_action_group.main[0].id
  }

  tags = merge(var.tags, {
    Site = var.site_name
  })
}

# Alert: High CPU
resource "azurerm_monitor_metric_alert" "high_cpu" {
  count = length(var.alert_recipients) > 0 ? 1 : 0

  name                = "alert-highcpu-${local.name_prefix}"
  resource_group_name = var.resource_group_name
  scopes              = [var.app_service_id]
  description         = "Alert when CPU exceeds threshold"
  severity            = 2 # Warning
  frequency           = "PT1M"
  window_size         = "PT${local.alert_config.alert_window_minutes}M"

  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = "CpuTime"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = local.alert_config.high_cpu_threshold
  }

  action {
    action_group_id = azurerm_monitor_action_group.main[0].id
  }

  tags = merge(var.tags, {
    Site = var.site_name
  })
}

# Alert: Response Time (MTTD < 5 minutes per spec)
resource "azurerm_monitor_metric_alert" "response_time" {
  count = length(var.alert_recipients) > 0 ? 1 : 0

  name                = "alert-responsetime-${local.name_prefix}"
  resource_group_name = var.resource_group_name
  scopes              = [var.app_service_id]
  description         = "Alert when response time exceeds 3 seconds"
  severity            = 2 # Warning
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = "HttpResponseTime"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 3 # 3 seconds per performance goal
  }

  action {
    action_group_id = azurerm_monitor_action_group.main[0].id
  }

  tags = merge(var.tags, {
    Site = var.site_name
  })
}
