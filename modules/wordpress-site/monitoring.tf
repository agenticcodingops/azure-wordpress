# Opt-in monitoring added in v4.1.0: standard availability tests, and the MySQL,
# 5xx-rate, health-check and Resource Health alert families.
#
# Everything here is off by default. Every count and for_each depends only on input
# variables, never on a resource ID, so an unknown ID (a shared plan created in the
# same apply, for example) cannot fail the plan with "Invalid for_each argument".
#
# No Azure Verified Module is used. Microsoft.Insights/webtests has no Terraform AVM
# module, and the metric-alert, scheduled-query-rule and activity-log-alert modules are
# only Proposed. The pre-v4.1.0 alerts and the action group live in main.tf.

# ============================================================================
# ALERT ROUTING
# ============================================================================

locals {
  # Every alert this module creates notifies the site action group (which exists only
  # when alert_recipients is non-empty) plus any extra action groups. A list, not a
  # set: its length stays known at plan time even when an extra ID is not.
  alert_action_group_ids = concat(azurerm_monitor_action_group.main[*].id, var.extra_action_group_ids)
  has_alert_route        = length(var.alert_recipients) > 0 || length(var.extra_action_group_ids) > 0

  # Alerts added in v4.1.0 that are switched on. Checked by the routing precondition
  # on azurerm_resource_group.main, so an enabled alert can never be created with
  # nobody to notify.
  new_alerts_enabled = (
    length(var.availability_tests) > 0 ||
    local.mon_config.alerts.mysql.enabled ||
    local.mon_config.alerts.http_5xx_rate.enabled ||
    local.mon_config.alerts.health_check.enabled ||
    local.mon_config.alerts.resource_health.enabled
  )
}

# ============================================================================
# STANDARD AVAILABILITY TESTS (N-of-M locations alert)
# Classic URL ping tests are retired by Microsoft on 2026-09-30 and are never created.
# ============================================================================

locals {
  availability_tests = {
    for key, test in var.availability_tests : key => merge(test, {
      url = test.url != null ? test.url : "https://${var.custom_domain}${test.path}"

      # null => check the certificate whenever the URL is https.
      ssl_check_enabled = test.ssl_check_enabled != null ? test.ssl_check_enabled : startswith(lower(test.url != null ? test.url : "https://"), "https://")

      # Microsoft's rule of thumb: alert when (locations - 2) fail, at least 1.
      failed_location_count = test.failed_location_count != null ? test.failed_location_count : max(1, length(test.geo_locations) - 2)

      # The smallest metric-alert window at least as long as one test interval.
      # There is no PT10M window, so 600 s and 900 s both use PT15M.
      window_size = test.frequency == 300 ? "PT5M" : "PT15M"
    })
  }
}

resource "azurerm_application_insights_standard_web_test" "main" {
  for_each = local.availability_tests

  name                    = "webtest-${each.key}-${local.name_prefix}"
  resource_group_name     = azurerm_resource_group.main.name
  location                = azurerm_application_insights.main.location # must match the component
  application_insights_id = azurerm_application_insights.main.id
  description             = each.value.description

  # Both are Go bools with no schema default: leaving them out creates a disabled test.
  enabled       = each.value.enabled
  retry_enabled = each.value.retry_enabled

  frequency     = each.value.frequency
  timeout       = each.value.timeout
  geo_locations = each.value.geo_locations

  request {
    url                              = each.value.url
    http_verb                        = each.value.http_verb
    follow_redirects_enabled         = each.value.follow_redirects_enabled
    parse_dependent_requests_enabled = each.value.parse_dependent_requests_enabled

    dynamic "header" {
      for_each = each.value.headers
      content {
        name  = header.key
        value = header.value
      }
    }
  }

  validation_rules {
    expected_status_code = each.value.expected_status_code
    ssl_check_enabled    = each.value.ssl_check_enabled
    # Null when unset, never 0: the provider rejects 0 (valid range 1-365).
    ssl_cert_remaining_lifetime = each.value.ssl_cert_remaining_lifetime

    dynamic "content" {
      for_each = each.value.content_match != null ? [each.value.content_match] : []
      content {
        content_match = content.value
        ignore_case   = each.value.content_match_ignore_case
        # The provider default is false, which FAILS the test when the text is found.
        pass_if_text_found = true
      }
    }
  }

  # Never set a hidden-link tag: the provider adds it on every write and strips it from
  # state, so a configured one would plan a change on every run.
  tags = local.common_tags

  # Do not start probing (and paging) before the site can answer: the custom hostname
  # binding and, with Front Door, its profile, route and custom domain.
  depends_on = [azurerm_app_service_custom_hostname_binding.main, module.front_door]
}

resource "azurerm_monitor_metric_alert" "availability" {
  for_each = local.availability_tests

  name                = "alert-avail-${each.key}-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  # This criteria type needs both the web test and the component in scope.
  scopes      = [azurerm_application_insights_standard_web_test.main[each.key].id, azurerm_application_insights.main.id]
  description = "Availability test ${each.key} failed from ${each.value.failed_location_count} or more of ${length(each.value.geo_locations)} locations"
  severity    = each.value.alert_severity
  frequency   = "PT1M" # below both PT5M and PT15M, as the API requires
  window_size = each.value.window_size

  application_insights_web_test_location_availability_criteria {
    web_test_id           = azurerm_application_insights_standard_web_test.main[each.key].id
    component_id          = azurerm_application_insights.main.id
    failed_location_count = each.value.failed_location_count
  }

  dynamic "action" {
    for_each = local.alert_action_group_ids
    content {
      action_group_id = action.value
    }
  }

  tags = local.common_tags
}

# ============================================================================
# MYSQL METRIC ALERTS (monitoring.alerts.mysql)
# ============================================================================

locals {
  mysql_alert_config = local.mon_config.alerts.mysql

  # Burstable is decided on the resolved SKU string, which must be known at plan time.
  db_is_burstable = can(regex("^B_", local.db_config.sku_name))

  # alert_window_minutes is not validated: it predates v4.1.0 and feeds the baseline
  # alerts as-is. Round it up to a window the metric-alert API accepts, so this alert
  # never adds an error of its own (the baseline alerts already reject odd values).
  aborted_connections_window = (
    local.alert_config.alert_window_minutes <= 1 ? "PT1M" :
    local.alert_config.alert_window_minutes <= 5 ? "PT5M" :
    local.alert_config.alert_window_minutes <= 15 ? "PT15M" :
    local.alert_config.alert_window_minutes <= 30 ? "PT30M" :
    local.alert_config.alert_window_minutes <= 60 ? "PT1H" :
    local.alert_config.alert_window_minutes <= 360 ? "PT6H" :
    local.alert_config.alert_window_minutes <= 720 ? "PT12H" : "P1D"
  )

  # One definitions map with fixed keys, filtered with `if`. The keys never depend on
  # a resource ID, so an unknown ID cannot fail the for_each.
  mysql_alert_definitions = {
    cpu_percent = {
      create      = true
      metric_name = "cpu_percent"
      aggregation = "Average"
      operator    = "GreaterThan"
      threshold   = local.mysql_alert_config.cpu_percent_threshold
      frequency   = "PT5M"
      window_size = "PT15M"
      description = "MySQL CPU above ${local.mysql_alert_config.cpu_percent_threshold}% (15-minute average)"
    }
    memory_percent = {
      create      = true
      metric_name = "memory_percent"
      aggregation = "Average"
      operator    = "GreaterThan"
      threshold   = local.mysql_alert_config.memory_percent_threshold
      frequency   = "PT5M"
      window_size = "PT15M"
      description = "MySQL memory above ${local.mysql_alert_config.memory_percent_threshold}% (15-minute average)"
    }
    storage_percent = {
      create      = true
      metric_name = "storage_percent"
      aggregation = "Maximum"
      operator    = "GreaterThan"
      threshold   = local.mysql_alert_config.storage_percent_threshold
      frequency   = "PT5M"
      window_size = "PT15M"
      description = "MySQL storage above ${local.mysql_alert_config.storage_percent_threshold}%"
    }
    # The one consumer of db_failure_threshold. aborted_connections supports Total only.
    aborted_connections = {
      create      = true
      metric_name = "aborted_connections"
      aggregation = "Total"
      operator    = "GreaterThan"
      threshold   = local.alert_config.db_failure_threshold
      frequency   = "PT1M"
      window_size = local.aborted_connections_window
      description = "More than ${local.alert_config.db_failure_threshold} aborted MySQL connections in ${local.aborted_connections_window}"
    }
    # Only with an explicit threshold: max_connections varies by SKU.
    active_connections = {
      create      = local.mysql_alert_config.active_connections_threshold != null
      metric_name = "active_connections"
      aggregation = "Maximum"
      operator    = "GreaterThan"
      threshold   = local.mysql_alert_config.active_connections_threshold
      frequency   = "PT5M"
      window_size = "PT15M"
      description = "MySQL active connections above ${coalesce(local.mysql_alert_config.active_connections_threshold, 0)}"
    }
    # Burstable SKUs only. The credit metrics have 15-minute and longer grains.
    cpu_credits_remaining = {
      create      = local.db_is_burstable
      metric_name = "cpu_credits_remaining"
      aggregation = "Average"
      operator    = "LessThan"
      threshold   = local.mysql_alert_config.cpu_credits_remaining_threshold
      frequency   = "PT15M"
      window_size = "PT30M"
      description = "MySQL CPU credits below ${local.mysql_alert_config.cpu_credits_remaining_threshold} (Burstable SKU)"
    }
  }

  mysql_alerts = {
    for key, alert in local.mysql_alert_definitions : key => alert
    if local.mysql_alert_config.enabled && alert.create
  }
}

resource "azurerm_monitor_metric_alert" "mysql" {
  for_each = local.mysql_alerts

  name                = "alert-mysql-${replace(each.key, "_", "")}-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [module.database.server_id]
  description         = each.value.description
  severity            = local.mysql_alert_config.severity
  frequency           = each.value.frequency
  window_size         = each.value.window_size

  criteria {
    metric_namespace = "Microsoft.DBforMySQL/flexibleServers"
    metric_name      = each.value.metric_name
    aggregation      = each.value.aggregation
    operator         = each.value.operator
    threshold        = each.value.threshold
  }

  dynamic "action" {
    for_each = local.alert_action_group_ids
    content {
      action_group_id = action.value
    }
  }

  tags = local.common_tags

  depends_on = [module.database]
}

# ============================================================================
# HTTP 5XX RATE LOG ALERT (monitoring.alerts.http_5xx_rate)
# The baseline http_5xx alert counts errors; this one alerts on their share of
# requests, which does not fire on a quiet site or page on a busy one.
# ============================================================================

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "http_5xx_rate" {
  count = local.mon_config.alerts.http_5xx_rate.enabled ? 1 : 0

  name                = "alert-5xxrate-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = coalesce(var.monitoring.log_analytics_workspace_location, var.location) # the workspace's region
  description         = "HTTP 5xx responses above ${local.mon_config.alerts.http_5xx_rate.threshold_percent}% of requests (at least ${local.mon_config.alerts.http_5xx_rate.minimum_requests} requests per window)"
  severity            = local.mon_config.alerts.http_5xx_rate.severity

  # The API allows exactly one scope, and it forces replacement.
  scopes               = [local.workspace_id]
  evaluation_frequency = local.mon_config.alerts.http_5xx_rate.evaluation_frequency
  window_duration      = local.mon_config.alerts.http_5xx_rate.window_duration

  # The provider defaults this to false, the opposite of a metric alert.
  auto_mitigation_enabled = true
  # AppServiceHTTPLogs may not exist yet on a brand-new workspace; see the README.
  skip_query_validation = true

  criteria {
    # Filtered on the production app's resource ID, so staging-slot traffic is excluded.
    # No bin(): one row per evaluation, hence 1 of 1 failing periods.
    query                   = <<-KQL
      AppServiceHTTPLogs
      | where _ResourceId =~ "${module.app_service.id}"
      | summarize total = count(), errors = countif(ScStatus >= 500)
      | where total >= ${local.mon_config.alerts.http_5xx_rate.minimum_requests}
      | extend error_rate = 100.0 * errors / total
    KQL
    time_aggregation_method = "Maximum"
    metric_measure_column   = "error_rate"
    operator                = "GreaterThan"
    threshold               = local.mon_config.alerts.http_5xx_rate.threshold_percent

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = local.alert_action_group_ids
  }

  tags = local.common_tags

  # The app's diagnostic setting is what ships AppServiceHTTPLogs to the workspace.
  depends_on = [azurerm_monitor_diagnostic_setting.app_service]
}

# ============================================================================
# HEALTH-CHECK ALERT (monitoring.alerts.health_check)
# The app always has a health check path (app_config.health_check_path).
# ============================================================================

resource "azurerm_monitor_metric_alert" "health_check" {
  count = local.mon_config.alerts.health_check.enabled ? 1 : 0

  name                = "alert-healthcheck-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [module.app_service.id]
  description         = "Health check status below ${local.mon_config.alerts.health_check.threshold}% healthy"
  severity            = local.mon_config.alerts.health_check.severity
  frequency           = "PT5M" # HealthCheckStatus has no grain below five minutes
  window_size         = local.mon_config.alerts.health_check.window_size

  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = "HealthCheckStatus"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = local.mon_config.alerts.health_check.threshold
  }

  dynamic "action" {
    for_each = local.alert_action_group_ids
    content {
      action_group_id = action.value
    }
  }

  tags = local.common_tags

  depends_on = [module.app_service]
}

# ============================================================================
# RESOURCE HEALTH ALERT (monitoring.alerts.resource_health)
# ============================================================================

locals {
  # The ternary form of the app-service module's create_plan: with use_shared_plan the
  # plan_id may be unknown at plan time, and a ternary never evaluates it then. The
  # result feeds only an attribute (scopes), never a count.
  site_owns_plan = local.app_config.use_shared_plan ? false : local.app_config.plan_id == null
}

resource "azurerm_monitor_activity_log_alert" "resource_health" {
  count = local.mon_config.alerts.resource_health.enabled ? 1 : 0

  name                = "alert-resourcehealth-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = "global" # Required; global, westeurope, northeurope or eastus2euap only
  description         = "Resource Health: a site resource became ${join(" or ", local.mon_config.alerts.resource_health.current)}"

  # Resource IDs, never the site resource group: with a shared plan the app lives in
  # the shared group. The plan is included only when this site owns it.
  scopes = concat(
    [module.app_service.id, module.database.server_id, module.key_vault.id, module.storage.account_id],
    local.site_owns_plan ? [module.app_service.plan_id] : []
  )

  criteria {
    category = "ResourceHealth"

    resource_health {
      current  = local.mon_config.alerts.resource_health.current
      previous = local.mon_config.alerts.resource_health.previous
      reason   = local.mon_config.alerts.resource_health.reasons
    }
  }

  dynamic "action" {
    for_each = local.alert_action_group_ids
    content {
      action_group_id = action.value
    }
  }

  tags = local.common_tags
}
