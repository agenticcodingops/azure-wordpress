# Opt-in monitoring added in v4.1.0: standard availability tests; the MySQL, 5xx-rate,
# health-check and Resource Health alert families; and diagnostic settings for the Key
# Vault, the blob service and the staging slot.
#
# Everything here is off by default. Every count and for_each depends only on input
# variables, never on a resource ID, so an unknown ID (a shared plan created in the
# same apply, for example) cannot fail the plan with "Invalid for_each argument".
#
# No Azure Verified Module is used. Microsoft.Insights/webtests has no Terraform AVM
# module, and the metric-alert, scheduled-query-rule and activity-log-alert modules are
# only Proposed. Diagnostic settings have no Terraform resource module, and the
# interfaces utility module would add telemetry resources to every consumer's plan.
# The pre-v4.1.0 alerts, the action group and the app and MySQL diagnostic settings
# live in main.tf.

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

# ============================================================================
# DIAGNOSTIC SETTINGS: KEY VAULT, BLOB SERVICE, STAGING SLOT (opt-in)
# The app service and MySQL settings are unconditional and live in main.tf.
# ============================================================================

locals {
  # The app-service module's own predicate, on the SKU it receives. Never count on
  # staging_slot_id != null: that ID is unknown until the slot exists.
  sku_supports_slots = can(regex("^(S|P)[0-9]", local.app_config.sku_name))

  # Per-target defaults for the three AVM-shaped inputs.
  diagnostic_setting_targets = {
    key_vault = {
      settings = var.key_vault_diagnostic_settings
      prefix   = "diag-keyvault"
      logs     = ["AuditEvent"]
      metrics  = ["AllMetrics"]
    }
    storage_blob = {
      settings = var.storage_blob_diagnostic_settings
      prefix   = "diag-blob"
      logs     = ["StorageRead", "StorageWrite", "StorageDelete"]
      metrics  = ["Transaction"] # not AllMetrics: the API expands it and the plan never settles
    }
    staging_slot = {
      settings = var.staging_slot_diagnostic_settings
      prefix   = "diag-appservice-staging"
      logs     = ["AppServiceHTTPLogs", "AppServiceConsoleLogs", "AppServiceAppLogs", "AppServicePlatformLogs"]
      metrics  = ["AllMetrics"]
    }
  }

  # Resolve each map against its target's defaults:
  # - logs/metrics null => the target defaults; entries with enabled = false are dropped,
  #   because azurerm's enabled_log and enabled_metric have no enabled attribute.
  # - no destination at all => the site workspace.
  diagnostic_settings = {
    for target, cfg in local.diagnostic_setting_targets : target => {
      for key, ds in cfg.settings : key => {
        name                = ds.name != null ? ds.name : "${cfg.prefix}-${var.site_name}-${key}"
        log_categories      = ds.logs == null ? cfg.logs : [for l in ds.logs : l.category if l.enabled && l.category != null]
        log_category_groups = ds.logs == null ? [] : [for l in ds.logs : l.category_group if l.enabled && l.category_group != null]
        metric_categories   = ds.metrics == null ? cfg.metrics : [for m in ds.metrics : m.category if m.enabled]

        log_analytics_destination_type = ds.log_analytics_destination_type
        log_analytics_workspace_id = ds.workspace_resource_id != null ? ds.workspace_resource_id : (
          ds.storage_account_resource_id == null && ds.event_hub_authorization_rule_resource_id == null && ds.marketplace_partner_resource_id == null ? local.workspace_id : null
        )
        storage_account_id             = ds.storage_account_resource_id
        eventhub_authorization_rule_id = ds.event_hub_authorization_rule_resource_id
        eventhub_name                  = ds.event_hub_name
        partner_solution_id            = ds.marketplace_partner_resource_id

        # Destinations as the caller wrote them, with a sentinel for the site workspace,
        # so the conflict check below does not wait for a workspace created in this apply.
        destination_keys = compact([
          ds.workspace_resource_id != null ? "workspace:${lower(ds.workspace_resource_id)}" : (
            ds.storage_account_resource_id == null && ds.event_hub_authorization_rule_resource_id == null && ds.marketplace_partner_resource_id == null ? "workspace:site" : ""
          ),
          ds.storage_account_resource_id != null ? "storage:${lower(ds.storage_account_resource_id)}" : "",
          ds.event_hub_authorization_rule_resource_id != null ? "eventhub:${lower(ds.event_hub_authorization_rule_resource_id)}/${ds.event_hub_name == null ? "" : lower(ds.event_hub_name)}" : "",
          ds.marketplace_partner_resource_id != null ? "partner:${lower(ds.marketplace_partner_resource_id)}" : "",
        ])
      }
    }
  }

  # What Azure would otherwise reject only at apply, per target: two settings with one
  # name (one resource ID, so each overwrites the other), or two settings sending a
  # category to the same destination. A category group counts as overlapping any log
  # category. The site workspace passed explicitly by ID is not recognised as such.
  diagnostic_setting_conflicts = {
    for target, settings in local.diagnostic_settings : target => concat(
      [
        for name in distinct([for ds in values(settings) : lower(ds.name)]) : "two entries are named ${name}"
        if length([for ds in values(settings) : ds if lower(ds.name) == name]) > 1
      ],
      flatten([
        for i, a in keys(settings) : [
          for j, b in keys(settings) : "${a} and ${b} send the same category to the same destination"
          if i < j && length(setintersection(settings[a].destination_keys, settings[b].destination_keys)) > 0 && (
            length(setintersection(settings[a].log_categories, settings[b].log_categories)) > 0 ||
            length(setintersection(settings[a].metric_categories, settings[b].metric_categories)) > 0 ||
            (length(settings[a].log_category_groups) > 0 && length(concat(settings[b].log_categories, settings[b].log_category_groups)) > 0) ||
            (length(settings[b].log_category_groups) > 0 && length(settings[a].log_categories) > 0)
          )
        ]
      ])
    )
  }
}

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  for_each = local.diagnostic_settings.key_vault

  name                           = each.value.name
  target_resource_id             = module.key_vault.id
  log_analytics_workspace_id     = each.value.log_analytics_workspace_id
  log_analytics_destination_type = each.value.log_analytics_destination_type
  storage_account_id             = each.value.storage_account_id
  eventhub_authorization_rule_id = each.value.eventhub_authorization_rule_id
  eventhub_name                  = each.value.eventhub_name
  partner_solution_id            = each.value.partner_solution_id

  dynamic "enabled_log" {
    for_each = each.value.log_categories
    content {
      category = enabled_log.value
    }
  }

  dynamic "enabled_log" {
    for_each = each.value.log_category_groups
    content {
      category_group = enabled_log.value
    }
  }

  dynamic "enabled_metric" {
    for_each = each.value.metric_categories
    content {
      category = enabled_metric.value
    }
  }

  lifecycle {
    precondition {
      condition     = length(each.value.log_categories) + length(each.value.log_category_groups) + length(each.value.metric_categories) > 0
      error_message = "key_vault_diagnostic_settings[\"${each.key}\"] enables no log and no metric. Leave logs or metrics null for the defaults, or enable at least one entry."
    }

    precondition {
      condition     = length(local.diagnostic_setting_conflicts.key_vault) == 0
      error_message = "key_vault_diagnostic_settings: ${join("; ", local.diagnostic_setting_conflicts.key_vault)}. Azure rejects both at apply: give each entry its own name, and send each category to a destination once."
    }
  }
}

resource "azurerm_monitor_diagnostic_setting" "storage_blob" {
  for_each = local.diagnostic_settings.storage_blob

  name = each.value.name
  # The blob service, not the account: the storage module exports only the account ID.
  target_resource_id             = "${module.storage.account_id}/blobServices/default"
  log_analytics_workspace_id     = each.value.log_analytics_workspace_id
  log_analytics_destination_type = each.value.log_analytics_destination_type
  storage_account_id             = each.value.storage_account_id
  eventhub_authorization_rule_id = each.value.eventhub_authorization_rule_id
  eventhub_name                  = each.value.eventhub_name
  partner_solution_id            = each.value.partner_solution_id

  dynamic "enabled_log" {
    for_each = each.value.log_categories
    content {
      category = enabled_log.value
    }
  }

  dynamic "enabled_log" {
    for_each = each.value.log_category_groups
    content {
      category_group = enabled_log.value
    }
  }

  dynamic "enabled_metric" {
    for_each = each.value.metric_categories
    content {
      category = enabled_metric.value
    }
  }

  lifecycle {
    precondition {
      condition     = length(each.value.log_categories) + length(each.value.log_category_groups) + length(each.value.metric_categories) > 0
      error_message = "storage_blob_diagnostic_settings[\"${each.key}\"] enables no log and no metric. Leave logs or metrics null for the defaults, or enable at least one entry."
    }

    precondition {
      condition     = length(local.diagnostic_setting_conflicts.storage_blob) == 0
      error_message = "storage_blob_diagnostic_settings: ${join("; ", local.diagnostic_setting_conflicts.storage_blob)}. Azure rejects both at apply: give each entry its own name, and send each category to a destination once."
    }
  }
}

resource "azurerm_monitor_diagnostic_setting" "staging_slot" {
  # Filtered on the SKU, which is known at plan time. See the check block below.
  for_each = { for key, ds in local.diagnostic_settings.staging_slot : key => ds if local.sku_supports_slots }

  name                           = each.value.name
  target_resource_id             = module.app_service.staging_slot_id
  log_analytics_workspace_id     = each.value.log_analytics_workspace_id
  log_analytics_destination_type = each.value.log_analytics_destination_type
  storage_account_id             = each.value.storage_account_id
  eventhub_authorization_rule_id = each.value.eventhub_authorization_rule_id
  eventhub_name                  = each.value.eventhub_name
  partner_solution_id            = each.value.partner_solution_id

  dynamic "enabled_log" {
    for_each = each.value.log_categories
    content {
      category = enabled_log.value
    }
  }

  dynamic "enabled_log" {
    for_each = each.value.log_category_groups
    content {
      category_group = enabled_log.value
    }
  }

  dynamic "enabled_metric" {
    for_each = each.value.metric_categories
    content {
      category = enabled_metric.value
    }
  }

  lifecycle {
    precondition {
      condition     = length(each.value.log_categories) + length(each.value.log_category_groups) + length(each.value.metric_categories) > 0
      error_message = "staging_slot_diagnostic_settings[\"${each.key}\"] enables no log and no metric. Leave logs or metrics null for the defaults, or enable at least one entry."
    }

    precondition {
      condition     = length(local.diagnostic_setting_conflicts.staging_slot) == 0
      error_message = "staging_slot_diagnostic_settings: ${join("; ", local.diagnostic_setting_conflicts.staging_slot)}. Azure rejects both at apply: give each entry its own name, and send each category to a destination once."
    }
  }
}

# A warning, not an error: a consumer that moves a site from S1 to B1 should not be
# blocked by a setting that simply has no slot to attach to.
check "staging_slot_diagnostic_settings_need_a_slot" {
  assert {
    condition     = length(var.staging_slot_diagnostic_settings) == 0 || local.sku_supports_slots
    error_message = "staging_slot_diagnostic_settings is set, but SKU ${local.app_config.sku_name} has no staging slot (only S* and P* do), so no slot diagnostic setting is created."
  }
}
