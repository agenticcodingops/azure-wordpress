# Opt-in monitoring added in v4.1.0: standard availability tests and their alerts.
#
# Everything here is off by default. Every count and for_each depends only on input
# variables, never on a resource ID, so an unknown ID (a shared plan created in the
# same apply, for example) cannot fail the plan with "Invalid for_each argument".
#
# No Azure Verified Module is used. Microsoft.Insights/webtests has no Terraform AVM
# module, and the metric-alert module is only Proposed. The pre-v4.1.0 alerts and the
# action group live in main.tf.

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
  new_alerts_enabled = length(var.availability_tests) > 0
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
