# WordPress Site Composition Variables
# Orchestrates Layer 1 → Layer 2 modules for a complete WordPress site

variable "project_name" {
  description = "Project name used in resource naming (lowercase, 2-24 chars)"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,22}[a-z0-9]$", var.project_name))
    error_message = "Project name must be 2-24 lowercase alphanumeric characters with optional hyphens."
  }
}

variable "site_name" {
  description = "Site name used for resource naming (lowercase, hyphens only)"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,20}[a-z0-9]$", var.site_name))
    error_message = "Site name must be 2-22 characters, start with letter, end with letter/number, contain only lowercase letters, numbers, and hyphens."
  }
}

variable "environment" {
  description = "Environment name (nonprod or production)"
  type        = string

  validation {
    condition     = contains(["nonprod", "production"], var.environment)
    error_message = "Environment must be 'nonprod' or 'production'."
  }
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
}

variable "tenant_id" {
  description = "Azure AD tenant ID"
  type        = string
}

# The deploying principal. Flat top-level variables, not object attributes, so a
# plan-time value never depends on how an object is assembled.
variable "deployer_object_id" {
  description = "Object ID of the principal that runs terraform apply; it gets the Terraform secret-management access policy on the site's Key Vault. Null (the default) keeps the module's own azurerm_client_config read. Set it, together with deployer_tenant_id, only when plan and apply run as different identities or when the caller needs its own depends_on on this module; pass a lowercase value known at plan time. The policy's object_id forces replacement, so a value that differs from the principal that created the existing policy replaces it: do that only as a planned identity cutover."
  type        = string
  default     = null

  validation {
    condition     = var.deployer_object_id == null || can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.deployer_object_id))
    error_message = "deployer_object_id must be a lowercase GUID (an uppercase value differs from the ID Azure returns and would force the policy to be replaced)."
  }
}

variable "deployer_tenant_id" {
  description = "Tenant ID of the principal that runs terraform apply, used on its Key Vault access policy. Null (the default) keeps the module's own azurerm_client_config read. Set it together with deployer_object_id, as a lowercase value."
  type        = string
  default     = null

  validation {
    condition     = var.deployer_tenant_id == null || can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.deployer_tenant_id))
    error_message = "deployer_tenant_id must be a lowercase GUID."
  }
}

# Site configuration
variable "custom_domain" {
  description = "Custom domain for the WordPress site"
  type        = string
}

variable "wordpress_version" {
  description = "Passed to app-service as docker_image_tag (the name is historical). Tag of Microsoft's WordPress container image (appsvc/wordpress-debian-php): the PHP version, not a WordPress version. Floating tags exist for 8.2 and 8.3 only; the 8.4 series is published as dated tags (for example 8.4_20260922.3.tuxprod), so \"8.4\" alone does not exist on the registry. A dated tag (8.x_YYYYMMDD.N.tuxprod) disables automatic platform image updates, which makes image patching the consumer's job."
  type        = string
  default     = "8.3"
}

# Database configuration
# NOTE: sku_name, backup_retention_days and geo_redundant_backup intentionally carry
# NO default. Their default is selected by environment in main.tf's db_config local;
# giving them an optional() default here would mean null never reaches that coalesce
# and the environment-aware branch could never run.
variable "database" {
  description = "Database configuration. sku_name, backup_retention_days and geo_redundant_backup default by environment when unset - see the Environment-aware Defaults section of the README. NOTE: geo_redundant_backup forces replacement of the MySQL server, so set it explicitly on an existing deployment before upgrading. mysql_version defaults to 8.0.21; changing it on an existing server is an irreversible major-version upgrade (plan it per agenticcodingops/trackroutinely#104, WP-43)."
  type = object({
    sku_name                  = optional(string)
    storage_size_gb           = optional(number, 100)
    storage_iops              = optional(number, 700)
    backup_retention_days     = optional(number)
    geo_redundant_backup      = optional(bool)
    high_availability_mode    = optional(string, "Disabled")
    storage_auto_grow_enabled = optional(bool, true)
    # Constant default, not environment-aware. See mysql_version in modules/database.
    mysql_version = optional(string, "8.0.21")
  })
  default = {}
}

# Storage configuration
variable "storage" {
  description = "Storage account configuration"
  type = object({
    additional_containers           = optional(map(object({ access_type = optional(string, "private") })), {})
    versioning_enabled              = optional(bool, true)
    blob_delete_retention_days      = optional(number, 30)
    container_delete_retention_days = optional(number, 30)
    lifecycle_policy_enabled        = optional(bool, true)
    lifecycle_cool_tier_days        = optional(number, 30)
    lifecycle_version_delete_days   = optional(number, 90)
    lifecycle_snapshot_delete_days  = optional(number, 90)
    lifecycle_prefix_match          = optional(list(string), ["uploads/"])
  })
  default = {}
}

# Data-plane network rules for Key Vault and Storage.
#
# These are deliberately top-level variables rather than attributes on the
# `key_vault`/`storage` objects: static analysers (Checkov CKV_AZURE_35, and
# Trivy) resolve a plain variable's default but cannot see through an
# `optional()` object attribute, so the secure default would be reported as a
# misconfiguration. `key_vault_name_suffix` already establishes this flat
# convention in this module.

variable "key_vault_public_network_access_enabled" {
  description = "Allow unrestricted public access to the Key Vault data plane. Defaults to false (deny). Terraform is not a trusted Azure service, so its calls to create secrets need either an entry in key_vault_network_acls_ip_rules or this set to true."
  type        = bool
  default     = false
}

variable "key_vault_network_acls_ip_rules" {
  description = "Public IPv4 addresses or CIDRs permitted to reach the Key Vault data plane. Add the deploying principal's egress IP (e.g. the CI runner)."
  type        = list(string)
  default     = []
}

variable "key_vault_network_acls_virtual_network_subnet_ids" {
  description = "Extra subnet IDs permitted to reach the Key Vault data plane. The site's App Service subnet is always included."
  type        = list(string)
  default     = []
}

# Key Vault lifecycle. Both default to null so the environment-aware branch in
# main.tf's kv_config local can fire - a non-null default here would be substituted
# before coalesce ever saw it, making that branch dead code (the bug fixed in #21).
variable "key_vault_purge_protection_enabled" {
  description = "Enable Key Vault purge protection. Defaults by environment when unset: true in production, false in nonprod. WARNING: Azure permits enabling this but never disabling it, so changing it on an existing vault forces a destroy and recreate."
  type        = bool
  default     = null
}

variable "key_vault_soft_delete_retention_days" {
  description = "Days a soft-deleted vault is retained (7-90). Defaults by environment when unset: 90 in production, 7 in nonprod. Azure fixes this at creation, so changing it on an existing vault forces a destroy and recreate."
  type        = number
  default     = null

  validation {
    condition     = var.key_vault_soft_delete_retention_days == null || try(var.key_vault_soft_delete_retention_days >= 7 && var.key_vault_soft_delete_retention_days <= 90, false)
    error_message = "key_vault_soft_delete_retention_days must be null or between 7 and 90."
  }
}

# WARNING: the WordPress Blob Storage plugin points media URLs at the account's own
# blob endpoint, so visitors fetch media directly from Azure rather than through the
# CDN. Unless the blob endpoint is fronted by a CDN custom domain, set this to "Allow"
# or media will 403 for end users. See modules/storage/README.md.
variable "storage_network_rules_default_action" {
  description = "Default action for the storage account's network rules. Defaults to Deny. Set to 'Allow' if media is served straight from the blob endpoint rather than through a CDN custom domain."
  type        = string
  default     = "Deny"

  validation {
    condition     = contains(["Allow", "Deny"], var.storage_network_rules_default_action)
    error_message = "Storage network rules default action must be 'Allow' or 'Deny'."
  }
}

variable "storage_network_rules_bypass" {
  description = "Traffic permitted to bypass the storage network rules. Valid values: AzureServices, Logging, Metrics, None."
  type        = set(string)
  default     = ["AzureServices"]
}

variable "storage_network_rules_ip_rules" {
  description = "Extra public IPv4 addresses or CIDRs permitted to reach the storage data plane. Cloudflare's live IPv4 egress ranges are added automatically when cdn_provider = 'cloudflare'. Azure Storage rejects IPv6 CIDRs and /31-/32 prefixes."
  type        = list(string)
  default     = []
}

variable "storage_network_rules_virtual_network_subnet_ids" {
  description = "Extra subnet IDs permitted to reach the storage data plane. The site's App Service subnet is always included."
  type        = list(string)
  default     = []
}

# SCM/Kudu network posture and publishing credentials for the App Service.
#
# Flat top-level variables rather than app_service object attributes, for the same
# reason as the key_vault_/storage_ block above: static analysers resolve a plain
# variable's default but cannot see through an optional() object attribute.
#
# All four default to the azurerm provider's own defaults, so upgrading from
# v3.0.0 without setting them produces no plan diff. None is environment-aware:
# making SCM 'Deny' in production only would lock an operator out of prod, the
# exact site where Kudu access matters most.
#
# WARNING: the SCM endpoint is a separate gate from the main site's IP rules AND
# a separate gate from authentication - both must pass. Setting the default action
# to 'Deny' without a matching allow-list entry costs you the Kudu SSH console,
# which is the only route to a manual `wp core update --major`. See
# modules/app-service/README.md.

variable "app_service_scm_ip_restrictions" {
  description = "Allow-list for the App Service SCM/Kudu endpoint, applied to both the site and its staging slot. Exactly one of ip_address, service_tag or virtual_network_subnet_id must be set per entry. Empty (the default) preserves current provider behaviour."
  type = list(object({
    ip_address                = optional(string)
    service_tag               = optional(string)
    virtual_network_subnet_id = optional(string)
    name                      = optional(string)
    priority                  = optional(number)
    action                    = optional(string, "Allow")
    description               = optional(string)
  }))
  default = []

  validation {
    condition = alltrue([
      for r in var.app_service_scm_ip_restrictions :
      length([for v in [r.ip_address, r.service_tag, r.virtual_network_subnet_id] : v if v != null && v != ""]) == 1
    ])
    error_message = "Each app_service_scm_ip_restrictions entry must set exactly one of ip_address, service_tag, or virtual_network_subnet_id."
  }

  validation {
    condition     = alltrue([for r in var.app_service_scm_ip_restrictions : contains(["Allow", "Deny"], r.action)])
    error_message = "SCM IP restriction action must be 'Allow' or 'Deny'."
  }
}

variable "app_service_scm_ip_restriction_default_action" {
  description = "Default action for SCM/Kudu traffic matching no app_service_scm_ip_restrictions entry. Defaults to 'Allow', matching the azurerm provider default. Set to 'Deny' to close Kudu to everything not allow-listed."
  type        = string
  default     = "Allow"

  validation {
    condition     = contains(["Allow", "Deny"], var.app_service_scm_ip_restriction_default_action)
    error_message = "SCM IP restriction default action must be 'Allow' or 'Deny'."
  }
}

variable "app_service_ftp_publish_basic_authentication_enabled" {
  description = "Enable basic authentication for FTP publishing on the site and its staging slot. Defaults to true, matching the azurerm provider default. FTP is already closed at the transport layer (ftps_state is Disabled)."
  type        = bool
  default     = true
}

variable "app_service_webdeploy_publish_basic_authentication_enabled" {
  description = "Enable basic authentication for WebDeploy/SCM publishing on the site and its staging slot. Defaults to true, matching the azurerm provider default. Disabling this stops FTP/S deployment from working, but does not change the FTP policy itself - ARM models the two as independent resources, so set app_service_ftp_publish_basic_authentication_enabled = false too."
  type        = bool
  default     = true
}

variable "app_service_storage_plugin_app_settings_enabled" {
  description = "Set the MICROSOFT_AZURE_* storage-plugin app settings on the site and its staging slot. Defaults to true, which keeps the behaviour of every earlier release. The container image does not read them (only the Microsoft Azure Storage for WordPress plugin does, as wp-config.php constants), so without that plugin they are inert, and false removes them - including the storage account key from the app's environment. The storage-key Key Vault secret is unaffected."
  type        = bool
  default     = true
  nullable    = false
}

# App Service configuration
variable "app_service" {
  description = "App Service configuration"
  type = object({
    plan_id                        = optional(string, null)
    use_shared_plan                = optional(bool, false)
    sku_name                       = optional(string, "P1v3")
    always_on                      = optional(bool, true)
    health_check_path              = optional(string)
    worker_count                   = optional(number, 1)
    extra_app_settings             = optional(map(string), {})
    extra_sticky_app_setting_names = optional(list(string), [])
    sticky_connection_string_names = optional(list(string), [])
    staging_app_settings_override  = optional(map(string), {})
    staging_always_on              = optional(bool, false)
  })
  default = {}
}

# Shared resource group for App Service (required when use_shared_plan = true)
# Azure requires App Service and its Plan to be in the same resource group
variable "shared_resource_group_name" {
  description = "Name of the shared resource group where the shared App Service Plan is located. Required when app_service.use_shared_plan = true."
  type        = string
  default     = null
}

# Shared App Service Plan SKU (required when use_shared_plan = true)
# Used to determine feature availability (e.g., B1 doesn't support deployment slots)
variable "shared_plan_sku" {
  description = "SKU of the shared App Service Plan. Required when app_service.use_shared_plan = true to determine feature availability."
  type        = string
  default     = null
}

# Front Door configuration
variable "front_door" {
  description = "Front Door configuration"
  type = object({
    enabled               = optional(bool, true)
    sku_name              = optional(string, "Premium_AzureFrontDoor")
    waf_mode              = optional(string)
    cache_uploads_minutes = optional(number, 180)
    cache_static_minutes  = optional(number, 180)
  })
  default = {}
}

# CDN Provider configuration
variable "cdn_provider" {
  description = "CDN provider: 'cloudflare' (uses Cloudflare CDN/WAF), 'azure_front_door' (uses Azure Front Door), 'direct' (no CDN)"
  type        = string
  default     = "direct"

  validation {
    condition     = contains(["cloudflare", "azure_front_door", "direct"], var.cdn_provider)
    error_message = "CDN provider must be 'cloudflare', 'azure_front_door', or 'direct'."
  }
}

# Cloudflare configuration (required when cdn_provider = cloudflare)
variable "cloudflare" {
  description = "Cloudflare configuration"
  type = object({
    enabled                        = optional(bool, false)
    account_id                     = optional(string, "")
    domain                         = optional(string, "")
    subdomain                      = optional(string, "")
    proxied                        = optional(bool, true)
    enable_waf                     = optional(bool, false) # Needs Pro or higher: rate limiting exceeds Free's 1 rule and 10 s timeout
    enable_page_rules              = optional(bool, true)  # Free plan: 3 rules (wp-admin bypass, wp-login bypass, wp-content cache)
    enable_cache_rules             = optional(bool, false) # Works on Free: 5 of the 10 cache rules it allows
    enable_zone_setting_overrides  = optional(bool, false) # Some settings can't be modified on Free plan
    enable_wordpress_optimizations = optional(bool, true)
  })
  default = {}
}

# Monitoring configuration
#
# The alert families under monitoring.alerts (mysql, http_5xx_rate, health_check,
# resource_health) were added in v4.1.0 and are all off by default. They are nested
# here, not flat, because none is a security control and none is environment-aware:
# constant optional() defaults are fine. An environment-aware default would need no
# optional() default and a selection in a *_config local instead (see database).
variable "monitoring" {
  description = "Monitoring configuration. alerts.mysql, alerts.http_5xx_rate, alerts.health_check and alerts.resource_health are opt-in alert families (enabled = false by default); enabling any of them needs alert_recipients or extra_action_group_ids. db_failure_threshold is the aborted-connections threshold of the MySQL family. log_analytics_workspace_location is the region of an external log_analytics_workspace_id: set it when that workspace is in another region and http_5xx_rate is enabled, because a log search alert rule must be in its workspace's region. See the README's Alerting section."
  type = object({
    log_analytics_workspace_id       = optional(string, null)
    log_analytics_workspace_location = optional(string) # the external workspace's region; see http_5xx_rate
    retention_days                   = optional(number)
    alerts = optional(object({
      http_5xx_threshold   = optional(number, 10)
      high_cpu_threshold   = optional(number, 80)
      db_failure_threshold = optional(number, 5)
      alert_window_minutes = optional(number, 5)
      mysql = optional(object({
        enabled                         = optional(bool, false)
        severity                        = optional(number, 2)
        cpu_percent_threshold           = optional(number, 80)
        memory_percent_threshold        = optional(number, 90)
        storage_percent_threshold       = optional(number, 85)
        active_connections_threshold    = optional(number)     # null => no active_connections alert (max_connections varies by SKU)
        cpu_credits_remaining_threshold = optional(number, 30) # Burstable (B_) SKUs only
      }), {})
      http_5xx_rate = optional(object({
        enabled              = optional(bool, false)
        severity             = optional(number, 2)
        threshold_percent    = optional(number, 5)
        minimum_requests     = optional(number, 20)
        window_duration      = optional(string, "PT15M")
        evaluation_frequency = optional(string, "PT5M") # PT1M is not offered
      }), {})
      health_check = optional(object({
        enabled     = optional(bool, false)
        severity    = optional(number, 1)
        threshold   = optional(number, 100)
        window_size = optional(string, "PT15M")
      }), {})
      resource_health = optional(object({
        enabled  = optional(bool, false)
        current  = optional(list(string), ["Degraded", "Unavailable"])
        previous = optional(list(string), ["Available", "Unknown"])
        reasons  = optional(list(string), ["PlatformInitiated", "Unknown"])
      }), {})
    }), {})
  })
  default = {}

  validation {
    condition     = var.monitoring.log_analytics_workspace_location == null || var.monitoring.log_analytics_workspace_id != null
    error_message = "monitoring.log_analytics_workspace_location applies only to an external workspace: set log_analytics_workspace_id too, or leave it null."
  }

  # Unused before 4.1.0; it now drives the aborted-connections alert, where a
  # negative threshold would always fire.
  validation {
    condition     = var.monitoring.alerts.db_failure_threshold >= 0
    error_message = "monitoring.alerts.db_failure_threshold must not be negative: it is the aborted-connections count of the MySQL alert family."
  }

  validation {
    condition = alltrue([
      for s in [var.monitoring.alerts.mysql.severity, var.monitoring.alerts.http_5xx_rate.severity, var.monitoring.alerts.health_check.severity] :
      contains([0, 1, 2, 3, 4], s)
    ])
    error_message = "monitoring.alerts: mysql.severity, http_5xx_rate.severity and health_check.severity must be 0-4 (0 is critical)."
  }

  validation {
    condition = alltrue([
      for t in [var.monitoring.alerts.mysql.cpu_percent_threshold, var.monitoring.alerts.mysql.memory_percent_threshold, var.monitoring.alerts.mysql.storage_percent_threshold] :
      t >= 0 && t <= 100
    ]) && var.monitoring.alerts.mysql.cpu_credits_remaining_threshold >= 0
    error_message = "monitoring.alerts.mysql: the percent thresholds must be 0-100, and cpu_credits_remaining_threshold must not be negative."
  }

  validation {
    condition     = var.monitoring.alerts.mysql.active_connections_threshold == null ? true : var.monitoring.alerts.mysql.active_connections_threshold >= 1
    error_message = "monitoring.alerts.mysql.active_connections_threshold must be at least 1, or null for no active-connections alert."
  }

  validation {
    condition     = var.monitoring.alerts.http_5xx_rate.threshold_percent >= 0 && var.monitoring.alerts.http_5xx_rate.threshold_percent < 100 && var.monitoring.alerts.http_5xx_rate.minimum_requests >= 1
    error_message = "monitoring.alerts.http_5xx_rate: threshold_percent must be at least 0 and below 100, and minimum_requests at least 1."
  }

  # The provider's own enums, minus PT1M evaluation: the rule always skips query
  # validation, which conflicts with a one-minute frequency. The window must hold at
  # least one evaluation interval, since the query counts the whole window once.
  validation {
    condition = (
      contains(["PT5M", "PT10M", "PT15M", "PT30M", "PT45M", "PT1H", "PT2H", "PT3H", "PT4H", "PT5H", "PT6H", "P1D"], var.monitoring.alerts.http_5xx_rate.evaluation_frequency) &&
      contains(["PT5M", "PT10M", "PT15M", "PT30M", "PT45M", "PT1H", "PT2H", "PT3H", "PT4H", "PT5H", "PT6H", "P1D", "P2D"], var.monitoring.alerts.http_5xx_rate.window_duration) &&
      lookup({ PT5M = 5, PT10M = 10, PT15M = 15, PT30M = 30, PT45M = 45, PT1H = 60, PT2H = 120, PT3H = 180, PT4H = 240, PT5H = 300, PT6H = 360, P1D = 1440, P2D = 2880 }, var.monitoring.alerts.http_5xx_rate.window_duration, 0) >=
      lookup({ PT5M = 5, PT10M = 10, PT15M = 15, PT30M = 30, PT45M = 45, PT1H = 60, PT2H = 120, PT3H = 180, PT4H = 240, PT5H = 300, PT6H = 360, P1D = 1440 }, var.monitoring.alerts.http_5xx_rate.evaluation_frequency, 100000)
    )
    error_message = "monitoring.alerts.http_5xx_rate: evaluation_frequency must be one of PT5M, PT10M, PT15M, PT30M, PT45M, PT1H-PT6H or P1D; window_duration one of PT5M, PT10M, PT15M, PT30M, PT45M, PT1H-PT6H, P1D or P2D, and at least as long as evaluation_frequency."
  }

  # HealthCheckStatus has no grain below five minutes; the alert evaluates every PT5M.
  validation {
    condition     = contains(["PT5M", "PT15M", "PT30M", "PT1H"], var.monitoring.alerts.health_check.window_size) && var.monitoring.alerts.health_check.threshold >= 0 && var.monitoring.alerts.health_check.threshold <= 100
    error_message = "monitoring.alerts.health_check: window_size must be PT5M, PT15M, PT30M or PT1H, and threshold 0-100."
  }

  validation {
    condition = (
      length(var.monitoring.alerts.resource_health.current) > 0 &&
      length(var.monitoring.alerts.resource_health.previous) > 0 &&
      length(var.monitoring.alerts.resource_health.reasons) > 0 &&
      alltrue([for v in concat(var.monitoring.alerts.resource_health.current, var.monitoring.alerts.resource_health.previous) : contains(["Available", "Degraded", "Unavailable", "Unknown"], v)]) &&
      alltrue([for v in var.monitoring.alerts.resource_health.reasons : contains(["PlatformInitiated", "UserInitiated", "Unknown"], v)])
    )
    error_message = "monitoring.alerts.resource_health: current and previous must be non-empty lists of Available, Degraded, Unavailable or Unknown; reasons a non-empty list of PlatformInitiated, UserInitiated or Unknown."
  }
}

variable "alert_recipients" {
  description = "Email addresses for alert notifications"
  type        = list(string)
  default     = []
}

# Extra alert routing, added in v4.1.0. A list, not a set, so its length stays known
# at plan time even when an entry is not.
variable "extra_action_group_ids" {
  description = "Additional action group resource IDs that every alert in this module notifies, alongside the site action group (which exists only when alert_recipients is non-empty). Use it to attach a platform-level group. Empty (the default) changes nothing. With no alert_recipients, setting it still creates the three baseline alerts (HTTP 5xx, CPU, response time), routed to these groups only."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for id in var.extra_action_group_ids : can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Insights/actionGroups/[^/]+$", id))])
    error_message = "Each extra_action_group_ids entry must be an action group resource ID (/subscriptions/.../resourceGroups/.../providers/Microsoft.Insights/actionGroups/...)."
  }

  validation {
    condition     = length(distinct(var.extra_action_group_ids)) == length(var.extra_action_group_ids)
    error_message = "extra_action_group_ids must not contain duplicates."
  }
}

# Standard availability tests, added in v4.1.0. Off when empty.
# Every null guard below is a conditional, not ||: Terraform before 1.12 evaluates
# both sides of || and &&, so `x == null || f(x)` still errors on a null x.
variable "availability_tests" {
  description = "Standard availability tests against the site's Application Insights component, one per map entry; each gets one metric alert that fires when failed_location_count or more locations fail. Empty (the default) creates nothing. url defaults to https://<custom_domain><path>, so tests probe the public site through the CDN. Requires alert_recipients or extra_action_group_ids. Each test is billed per execution; see the README before adding locations or raising the frequency."
  type = map(object({
    url                              = optional(string)      # null => "https://<custom_domain><path>"
    path                             = optional(string, "/") # used only when url is null
    http_verb                        = optional(string, "GET")
    headers                          = optional(map(string), {}) # Host and User-Agent are reserved by the service
    expected_status_code             = optional(number, 200)
    content_match                    = optional(string) # the test passes only if this text is found
    content_match_ignore_case        = optional(bool, false)
    ssl_check_enabled                = optional(bool)        # null => true when the URL is https
    ssl_cert_remaining_lifetime      = optional(number)      # days, 1-365; needs an https URL and the SSL check
    frequency                        = optional(number, 300) # seconds: 300, 600 or 900
    timeout                          = optional(number, 30)  # seconds: 30, 60, 90 or 120
    geo_locations                    = optional(list(string), ["emea-ru-msa-edge", "emea-se-sto-edge", "emea-nl-ams-azr", "emea-gb-db3-azr", "emea-fr-pra-edge"])
    failed_location_count            = optional(number) # null => max(1, locations - 2)
    follow_redirects_enabled         = optional(bool, true)
    parse_dependent_requests_enabled = optional(bool, false) # true also fetches media, which a deny-by-default blob endpoint refuses
    retry_enabled                    = optional(bool, true)
    enabled                          = optional(bool, true)
    alert_severity                   = optional(number, 1)
    description                      = optional(string)
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for key in keys(var.availability_tests) : can(regex("^[a-z0-9][a-z0-9-]{0,19}$", key))])
    error_message = "availability_tests keys are used in resource names: 1-20 characters of lowercase letters, digits and hyphens, starting with a letter or digit."
  }

  validation {
    condition     = alltrue([for t in values(var.availability_tests) : t.url == null ? true : can(regex("^(?i)https?://[^/]+", t.url))])
    error_message = "availability_tests.url must be an absolute http:// or https:// URL."
  }

  validation {
    condition     = alltrue([for t in values(var.availability_tests) : startswith(t.path, "/")])
    error_message = "availability_tests.path must start with /."
  }

  validation {
    condition     = alltrue([for t in values(var.availability_tests) : contains(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"], t.http_verb)])
    error_message = "availability_tests.http_verb must be one of GET, POST, PUT, PATCH, DELETE, HEAD or OPTIONS."
  }

  validation {
    condition     = alltrue([for t in values(var.availability_tests) : alltrue([for h in keys(t.headers) : !contains(["host", "user-agent"], lower(h))])])
    error_message = "availability_tests.headers cannot set Host or User-Agent: the service reserves both."
  }

  validation {
    condition     = alltrue([for t in values(var.availability_tests) : t.expected_status_code >= 100 && t.expected_status_code <= 599 && floor(t.expected_status_code) == t.expected_status_code])
    error_message = "availability_tests.expected_status_code must be an HTTP status code between 100 and 599."
  }

  validation {
    condition     = alltrue([for t in values(var.availability_tests) : t.content_match == null ? true : length(t.content_match) > 0])
    error_message = "availability_tests.content_match must be non-empty when set."
  }

  validation {
    condition     = alltrue([for t in values(var.availability_tests) : contains([300, 600, 900], t.frequency)])
    error_message = "availability_tests.frequency must be 300, 600 or 900 seconds."
  }

  validation {
    condition     = alltrue([for t in values(var.availability_tests) : contains([30, 60, 90, 120], t.timeout)])
    error_message = "availability_tests.timeout must be 30, 60, 90 or 120 seconds."
  }

  validation {
    condition = alltrue([for t in values(var.availability_tests) : length(t.geo_locations) >= 1 && length(t.geo_locations) <= 16 && length(distinct(t.geo_locations)) == length(t.geo_locations) && alltrue([for l in t.geo_locations : contains([
      "us-va-ash-azr", "us-il-ch1-azr", "us-tx-sn1-azr", "us-ca-sjc-azr", "us-fl-mia-edge",
      "emea-ru-msa-edge", "emea-se-sto-edge", "emea-nl-ams-azr", "emea-gb-db3-azr", "emea-fr-pra-edge", "emea-ch-zrh-edge",
      "apac-hk-hkn-azr", "apac-sg-sin-azr", "apac-jp-kaw-edge", "emea-au-syd-edge", "latam-br-gru-edge",
    ], l)])])
    error_message = "availability_tests.geo_locations must hold 1-16 distinct location IDs from Microsoft's public list (for example emea-nl-ams-azr or us-va-ash-azr); see the README."
  }

  validation {
    condition     = alltrue([for t in values(var.availability_tests) : t.failed_location_count == null ? true : (t.failed_location_count >= 1 && t.failed_location_count <= length(t.geo_locations))])
    error_message = "availability_tests.failed_location_count must be between 1 and the number of geo_locations."
  }

  # Mirrors the provider's https check, and stops a lifetime from being silently dropped
  # (the provider sends it only with the SSL check on), which would diff on every plan.
  validation {
    condition = alltrue([for t in values(var.availability_tests) : t.ssl_cert_remaining_lifetime == null ? true : (
      t.ssl_cert_remaining_lifetime >= 1 && t.ssl_cert_remaining_lifetime <= 365 &&
      (t.ssl_check_enabled == null ? true : t.ssl_check_enabled) &&
      (t.url == null ? true : startswith(lower(t.url), "https://"))
    )])
    error_message = "availability_tests.ssl_cert_remaining_lifetime must be 1-365 days, and needs an https URL with ssl_check_enabled left null or true."
  }

  validation {
    condition     = alltrue([for t in values(var.availability_tests) : t.ssl_check_enabled == true ? (t.url == null ? true : startswith(lower(t.url), "https://")) : true])
    error_message = "availability_tests.ssl_check_enabled = true needs an https URL."
  }

  validation {
    condition     = alltrue([for t in values(var.availability_tests) : contains([0, 1, 2, 3, 4], t.alert_severity)])
    error_message = "availability_tests.alert_severity must be 0-4 (0 is critical)."
  }
}

# Networking configuration
variable "networking" {
  description = "Networking configuration"
  type = object({
    vnet_address_space           = optional(string, "10.0.0.0/16")
    app_subnet_cidr              = optional(string, "10.0.0.0/24")
    db_subnet_cidr               = optional(string, "10.0.1.0/24")
    private_endpoint_subnet_cidr = optional(string, "10.0.2.0/24")
  })
  default = {}
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# Additional Key Vault secrets supplied by the consumer
# Additive pass-through: the module's own secrets are merged last, so a consumer can
# never clobber db-password, storage-key or appinsights-connection.
variable "extra_secrets" {
  description = "Additional secrets to store in the site's Key Vault, as secret name => value. Module-owned names (db-password, storage-key, appinsights-connection) take precedence and cannot be overridden. Keys must be known at plan time."
  type        = map(string)
  sensitive   = true
  default     = {}
}

# App settings rendered as Key Vault references to secrets in this site's vault
# Resolved inside the module because feeding the module's own key_vault output back
# into its input would be a self-referential cycle.
variable "extra_secret_app_settings" {
  description = "Map of App Service app setting name => secret name in the site's Key Vault. Each entry is rendered as @Microsoft.KeyVault(SecretUri=...) and applied to both the production app and the staging slot. Takes precedence over app_service.extra_app_settings on key collision."
  type        = map(string)
  default     = {}
}

# Key Vault name suffix to avoid conflicts with soft-deleted vaults
variable "key_vault_name_suffix" {
  description = "Suffix appended to Key Vault name. Bump this to avoid conflicts with soft-deleted vaults that have purge protection enabled."
  type        = string
  default     = "9"
}

# Resource lock to prevent accidental deletion
# Requires "User Access Administrator" role on the deploying service principal
variable "enable_resource_lock" {
  description = "Enable CanNotDelete lock on the resource group (requires User Access Administrator role)"
  type        = bool
  default     = false
}

# App Service Plan density validation - DEPRECATED: nothing reads this input.
variable "plan_density_limit" {
  description = "DEPRECATED, and has no effect: nothing in this module reads it, so it enforces no limit on sites per App Service Plan. It is kept, with its validation, only so existing configurations that set it still plan, and will be removed in the next major release. Remove it from your configuration."
  type        = number
  default     = 10

  validation {
    condition     = var.plan_density_limit >= 1 && var.plan_density_limit <= 20
    error_message = "Plan density limit must be between 1 and 20."
  }
}
