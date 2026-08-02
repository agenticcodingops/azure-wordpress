# WordPress Site Composition
# Orchestrates Layer 1 → Layer 2 modules for a complete WordPress deployment
# CRITICAL: Layer 1 MUST complete before Layer 2 (explicit depends_on)
#
# Dependency Order:
# 1. Resource Group + Random Password
# 2. Layer 1: Networking, DNS Zones
# 3. App Insights (early - breaks circular dependency)
# 4. Layer 2: Database, Storage, Key Vault (with secrets)
# 5. Layer 2: App Service (needs Key Vault secrets)
# 6. Layer 2: Diagnostic Settings + Alerts (after App Service)
# 7. Layer 2: Front Door (optional, after App Service)

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    # Constrained to 4.x: the sub-modules use arguments that azurerm 5.x renamed
    # or removed. Without an upper bound, a fresh init resolves 5.x and fails.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = ">= 1.12.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
    # Constrained to 5.x: data.cloudflare_ip_ranges exposes ipv4_cidrs/ipv6_cidrs
    # in 5.x but ipv4_cidr_blocks/ipv6_cidr_blocks in 4.x, and this module uses
    # the 5.x names below.
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9.0"
    }
  }
}

# Fetch live Cloudflare egress IP ranges at apply time (public, no auth required).
# Only instantiated when cdn_provider = cloudflare to avoid requiring a Cloudflare
# provider configuration when Front Door or direct is used instead.
data "cloudflare_ip_ranges" "current" {
  count = var.cdn_provider == "cloudflare" ? 1 : 0
}

locals {
  # Short environment suffix for naming
  env_suffix = var.environment == "nonprod" ? "np" : "prod"

  # Resource naming prefix
  name_prefix = "${var.project_name}-${var.site_name}-${local.env_suffix}"

  # Common tags
  # Environment uses FinOps-compliant values: Dev, Stage, Prod
  environment_tag = var.environment == "nonprod" ? "Dev" : "Prod"

  common_tags = merge(var.tags, {
    Environment = local.environment_tag
    Site        = var.site_name
    Service     = "WordPress"
    ManagedBy   = "terraform"
    Project     = var.project_name
  })

  # Database defaults with environment-aware settings
  db_config = {
    sku_name               = coalesce(var.database.sku_name, var.environment == "production" ? "GP_Standard_D2ds_v4" : "B_Standard_B2s")
    storage_size_gb        = coalesce(var.database.storage_size_gb, 100)
    storage_iops           = coalesce(var.database.storage_iops, 700)
    backup_retention_days  = coalesce(var.database.backup_retention_days, var.environment == "production" ? 30 : 7)
    geo_redundant_backup   = coalesce(var.database.geo_redundant_backup, var.environment == "production")
    high_availability_mode = coalesce(var.database.high_availability_mode, "Disabled")
  }

  # Key Vault lifecycle defaults with environment-aware settings.
  # Purge protection is a production control: on nonprod, which is destroyed and rebuilt
  # deliberately, it buys nothing and locks the vault name for the full retention window
  # against everyone - see modules/key-vault/README.md.
  # NOTE: both variables must default to null in variables.tf or these branches are
  # unreachable, because optional()/non-null defaults are substituted before coalesce runs.
  kv_config = {
    purge_protection_enabled   = coalesce(var.key_vault_purge_protection_enabled, var.environment == "production")
    soft_delete_retention_days = coalesce(var.key_vault_soft_delete_retention_days, var.environment == "production" ? 90 : 7)
  }

  # App Service defaults
  # When using a shared plan, use the shared plan's SKU for feature detection (e.g., slot support)
  # This ensures the app-service module correctly determines what features are available
  effective_sku = coalesce(var.app_service.use_shared_plan, false) && var.shared_plan_sku != null ? var.shared_plan_sku : coalesce(var.app_service.sku_name, "P1v3")

  app_config = {
    plan_id           = var.app_service.plan_id
    use_shared_plan   = coalesce(var.app_service.use_shared_plan, false)
    sku_name          = local.effective_sku
    always_on         = coalesce(var.app_service.always_on, true)
    health_check_path = coalesce(var.app_service.health_check_path, "/wp-includes/images/blank.gif")
    worker_count      = coalesce(var.app_service.worker_count, 1)
  }

  # Resource group for App Service
  # Azure requires App Service and App Service Plan to be in the same resource group (webspace)
  # When using a shared plan, we MUST use the shared resource group
  app_service_resource_group = coalesce(var.app_service.use_shared_plan, false) && var.shared_resource_group_name != null ? var.shared_resource_group_name : azurerm_resource_group.main.name

  # Front Door defaults
  # IMPORTANT: Front Door is only enabled when cdn_provider = azure_front_door
  # When cdn_provider = cloudflare, Front Door is disabled to avoid duplicate CDN costs
  fd_config = {
    enabled               = var.cdn_provider == "azure_front_door" && coalesce(var.front_door.enabled, true)
    sku_name              = coalesce(var.front_door.sku_name, "Premium_AzureFrontDoor")
    waf_mode              = coalesce(var.front_door.waf_mode, var.environment == "production" ? "Prevention" : "Detection")
    cache_uploads_minutes = coalesce(var.front_door.cache_uploads_minutes, 180)
    cache_static_minutes  = coalesce(var.front_door.cache_static_minutes, 180)
  }

  # Cloudflare configuration
  # Note: Use try() for string fields to handle empty strings gracefully when cdn_provider != "cloudflare"
  # Defaults are set for Cloudflare Free plan compatibility (WAF, page rules, rulesets require paid plans)
  cf_config = {
    enabled                        = var.cdn_provider == "cloudflare" && coalesce(var.cloudflare.enabled, false)
    account_id                     = try(var.cloudflare.account_id, "") != "" ? var.cloudflare.account_id : ""
    domain                         = try(var.cloudflare.domain, "") != "" ? var.cloudflare.domain : ""
    subdomain                      = try(var.cloudflare.subdomain, "") != "" ? var.cloudflare.subdomain : ""
    proxied                        = coalesce(var.cloudflare.proxied, true)
    enable_waf                     = coalesce(var.cloudflare.enable_waf, false)                    # Free plan: WAF not available
    enable_page_rules              = coalesce(var.cloudflare.enable_page_rules, true)              # Free plan: 3 rules (wp-admin bypass, wp-login bypass, wp-content cache)
    enable_cache_rules             = coalesce(var.cloudflare.enable_cache_rules, false)            # Requires paid plan
    enable_zone_setting_overrides  = coalesce(var.cloudflare.enable_zone_setting_overrides, false) # Some settings not editable on Free
    enable_wordpress_optimizations = coalesce(var.cloudflare.enable_wordpress_optimizations, true)
  }

  # Monitoring defaults
  mon_config = {
    log_analytics_workspace_id = var.monitoring.log_analytics_workspace_id
    retention_days             = coalesce(var.monitoring.retention_days, var.environment == "production" ? 90 : 30)
    alerts                     = var.monitoring.alerts
  }

  # Networking defaults
  net_config = {
    vnet_address_space           = coalesce(var.networking.vnet_address_space, "10.0.0.0/16")
    app_subnet_cidr              = coalesce(var.networking.app_subnet_cidr, "10.0.0.0/24")
    db_subnet_cidr               = coalesce(var.networking.db_subnet_cidr, "10.0.1.0/24")
    private_endpoint_subnet_cidr = coalesce(var.networking.private_endpoint_subnet_cidr, "10.0.2.0/24")
  }

  # Create Log Analytics Workspace if not provided
  create_workspace = var.monitoring.log_analytics_workspace_id == null
}

# Resource Group for this site
resource "azurerm_resource_group" "main" {
  name     = "rg-${var.project_name}-${var.site_name}-${local.env_suffix}"
  location = var.location
  tags     = local.common_tags
}

# Generate database password
resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# ============================================================================
# LAYER 1: FOUNDATION
# These modules MUST complete before Layer 2 can deploy
# ============================================================================

# Networking Module
module "networking" {
  source = "../networking"

  project_name        = var.project_name
  site_name           = var.site_name
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name

  vnet_address_space           = local.net_config.vnet_address_space
  app_subnet_cidr              = local.net_config.app_subnet_cidr
  db_subnet_cidr               = local.net_config.db_subnet_cidr
  private_endpoint_subnet_cidr = local.net_config.private_endpoint_subnet_cidr

  tags = local.common_tags
}

# DNS Zones Module
module "dns_zones" {
  source = "../dns-zones"

  project_name        = var.project_name
  site_name           = var.site_name
  resource_group_name = azurerm_resource_group.main.name
  vnet_id             = module.networking.vnet_id

  tags = local.common_tags

  # Explicit dependency on networking
  depends_on = [module.networking]
}

# ============================================================================
# EARLY MONITORING RESOURCES (BREAKS CIRCULAR DEPENDENCY)
# App Insights + Log Analytics created early so connection string is available
# for Key Vault before App Service is created
# ============================================================================

# Log Analytics Workspace (shared per environment)
resource "azurerm_log_analytics_workspace" "main" {
  count = local.create_workspace ? 1 : 0

  name                = "log-${local.name_prefix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = local.mon_config.retention_days

  tags = local.common_tags
}

# Application Insights (created early for connection string)
resource "azurerm_application_insights" "main" {
  name                = "appi-${local.name_prefix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  workspace_id        = local.create_workspace ? azurerm_log_analytics_workspace.main[0].id : var.monitoring.log_analytics_workspace_id
  application_type    = "web"
  retention_in_days   = local.mon_config.retention_days

  tags = local.common_tags
}

# ============================================================================
# LAYER 2: APPLICATION
# These modules depend on Layer 1 completion
# CRITICAL: depends_on ensures Layer 1 → Layer 2 ordering
# ============================================================================

# Database Module
module "database" {
  source = "../database"

  project_name        = var.project_name
  site_name           = var.site_name
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name

  db_subnet_id        = module.networking.db_subnet_id
  private_dns_zone_id = module.dns_zones.mysql_dns_zone_id

  sku_name                  = local.db_config.sku_name
  storage_size_gb           = local.db_config.storage_size_gb
  storage_iops              = local.db_config.storage_iops
  backup_retention_days     = local.db_config.backup_retention_days
  geo_redundant_backup      = local.db_config.geo_redundant_backup
  high_availability_mode    = local.db_config.high_availability_mode
  storage_auto_grow_enabled = coalesce(var.database.storage_auto_grow_enabled, true)

  # Allow burstable SKUs for cost optimization (user choice)
  enforce_production_sku = false

  admin_username = "wpadmin"
  admin_password = random_password.db.result

  tags = local.common_tags

  # Explicit dependency on Layer 1
  depends_on = [
    module.networking,
    module.dns_zones
  ]
}

# Storage Module
module "storage" {
  source = "../storage"

  project_name        = var.project_name
  site_name           = var.site_name
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name

  additional_containers           = var.storage.additional_containers
  versioning_enabled              = var.storage.versioning_enabled
  blob_delete_retention_days      = var.storage.blob_delete_retention_days
  container_delete_retention_days = var.storage.container_delete_retention_days
  lifecycle_policy_enabled        = var.storage.lifecycle_policy_enabled
  lifecycle_cool_tier_days        = var.storage.lifecycle_cool_tier_days
  lifecycle_version_delete_days   = var.storage.lifecycle_version_delete_days
  lifecycle_snapshot_delete_days  = var.storage.lifecycle_snapshot_delete_days
  lifecycle_prefix_match          = var.storage.lifecycle_prefix_match

  # Data-plane network rules.
  # The App Service subnet is always allow-listed (it carries the Microsoft.Storage
  # service endpoint), so the WordPress plugin can read and write media.
  # When Cloudflare is the CDN we also allow-list its live IPv4 egress ranges, which
  # covers origin pulls if the blob endpoint is fronted by a Cloudflare custom domain.
  # Cloudflare's IPv6 ranges are intentionally omitted: Azure Storage IP rules are
  # IPv4-only and reject IPv6 CIDRs.
  # See https://developers.cloudflare.com/fundamentals/concepts/cloudflare-ip-addresses/
  network_rules_default_action = var.storage_network_rules_default_action
  network_rules_bypass         = var.storage_network_rules_bypass
  network_rules_ip_rules = distinct(concat(
    var.cdn_provider == "cloudflare" ? data.cloudflare_ip_ranges.current[0].ipv4_cidrs : [],
    var.storage_network_rules_ip_rules
  ))
  network_rules_virtual_network_subnet_ids = distinct(concat(
    [module.networking.app_subnet_id],
    var.storage_network_rules_virtual_network_subnet_ids
  ))

  tags = local.common_tags

  # Explicit dependency on Layer 1
  depends_on = [module.networking]
}

locals {
  # Secrets this module owns. Merged LAST over var.extra_secrets so a consumer-supplied
  # entry can never clobber the DB password, storage key or App Insights connection string.
  module_secrets = {
    "db-password"            = random_password.db.result
    "storage-key"            = module.storage.primary_access_key
    "appinsights-connection" = azurerm_application_insights.main.connection_string
  }
}

# Key Vault Module
# Created BEFORE app_service - uses placeholder for principal_id
# Access policy is added later after app_service creates its managed identity
module "key_vault" {
  source = "../key-vault"

  project_name        = var.project_name
  site_name           = var.site_name
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tenant_id           = var.tenant_id

  # Use a placeholder principal ID - will be updated after app_service creates
  app_service_principal_id = "00000000-0000-0000-0000-000000000000"

  # Key Vault name suffix (avoids soft-delete conflicts)
  name_suffix = var.key_vault_name_suffix

  # Vault lifecycle. Both are fixed by Azure at creation - purge protection can be
  # turned on but never off, and the retention window cannot be updated - so changing
  # either on an existing vault plans a destroy and recreate.
  purge_protection_enabled   = local.kv_config.purge_protection_enabled
  soft_delete_retention_days = local.kv_config.soft_delete_retention_days

  # Network rules. The App Service subnet is always allow-listed - it carries the
  # Microsoft.KeyVault service endpoint (see networking module) and the site's
  # managed identity resolves Key Vault references from there.
  public_network_access_enabled = var.key_vault_public_network_access_enabled
  network_acls_ip_rules         = var.key_vault_network_acls_ip_rules
  network_acls_virtual_network_subnet_ids = distinct(concat(
    [module.networking.app_subnet_id],
    var.key_vault_network_acls_virtual_network_subnet_ids
  ))

  # Secrets are available now because we created App Insights early.
  # Consumer-supplied extras first, module-owned second: merge() gives later maps
  # precedence, so the module's own secret names always win.
  secrets = merge(var.extra_secrets, local.module_secrets)

  tags = local.common_tags

  # Explicit dependency on Layer 1 and storage
  depends_on = [
    module.networking,
    module.storage,
    azurerm_application_insights.main
  ]
}

locals {
  # Key Vault references for consumer-supplied secrets, built here rather than by the
  # consumer: referencing this module's key_vault output from its own input would be a
  # cycle. The app-service module applies extra_app_settings to the staging slot too.
  extra_secret_app_settings = {
    for setting_name, secret_name in var.extra_secret_app_settings :
    setting_name => "@Microsoft.KeyVault(SecretUri=${module.key_vault.secret_versionless_uris[secret_name]})"
  }
}

# App Service Module (creates managed identity)
# NOTE: When using shared plan, App Service is in the shared resource group
# This is required because Azure mandates App Service and Plan be in same resource group
module "app_service" {
  source = "../app-service"

  project_name        = var.project_name
  site_name           = var.site_name
  environment         = var.environment
  location            = var.location
  resource_group_name = local.app_service_resource_group

  app_subnet_id = module.networking.app_subnet_id

  plan_id           = local.app_config.plan_id
  use_shared_plan   = local.app_config.use_shared_plan
  sku_name          = local.app_config.sku_name
  always_on         = local.app_config.always_on
  health_check_path = local.app_config.health_check_path
  worker_count      = local.app_config.worker_count

  docker_image_tag = var.wordpress_version

  database_host     = module.database.server_fqdn
  database_name     = module.database.database_name
  database_username = "wpadmin"

  # Key Vault references
  # Note: Using try() to handle partial state during terraform import operations
  # When importing secrets one at a time, the map may not contain all keys yet
  key_vault_uri                = module.key_vault.uri
  database_password_secret_uri = try(module.key_vault.secret_versionless_uris["db-password"], "")

  storage_account_name          = module.storage.account_name
  storage_container_name        = module.storage.container_name
  storage_access_key_secret_uri = try(module.key_vault.secret_versionless_uris["storage-key"], "")

  custom_domain = var.custom_domain

  app_insights_connection_string_secret_uri = try(module.key_vault.secret_versionless_uris["appinsights-connection"], "")

  # Staging and extra settings
  # Generated Key Vault references win over literal extra_app_settings on key collision
  extra_app_settings             = merge(coalesce(var.app_service.extra_app_settings, {}), local.extra_secret_app_settings)
  extra_sticky_app_setting_names = coalesce(var.app_service.extra_sticky_app_setting_names, [])
  sticky_connection_string_names = coalesce(var.app_service.sticky_connection_string_names, [])
  staging_app_settings_override  = coalesce(var.app_service.staging_app_settings_override, {})
  staging_always_on              = coalesce(var.app_service.staging_always_on, false)

  # CDN provider configuration - controls IP restrictions
  # NOTE: front_door_id is NOT passed here to avoid circular dependency
  # The azapi_update_resource below updates IP restrictions after Front Door is created
  cdn_provider       = var.cdn_provider
  front_door_enabled = local.fd_config.enabled

  # Live Cloudflare IP ranges fetched at apply time — keeps origin restrictions current
  # as Cloudflare adds new egress CIDRs. Null when not using Cloudflare (falls back to
  # built-in list in the app-service module, which is harmless since rules aren't applied).
  cloudflare_ipv4_cidr_blocks = var.cdn_provider == "cloudflare" ? data.cloudflare_ip_ranges.current[0].ipv4_cidrs : null
  cloudflare_ipv6_cidr_blocks = var.cdn_provider == "cloudflare" ? data.cloudflare_ip_ranges.current[0].ipv6_cidrs : null

  tags = local.common_tags

  # Explicit dependency on Layer 1 and other Layer 2 modules
  depends_on = [
    module.networking,
    module.database,
    module.storage,
    module.key_vault
  ]
}

# Update Key Vault access policy for App Service managed identity
resource "azurerm_key_vault_access_policy" "app_service_update" {
  key_vault_id = module.key_vault.id
  tenant_id    = var.tenant_id
  object_id    = module.app_service.principal_id

  secret_permissions = [
    "Get",
    "List"
  ]

  depends_on = [
    module.key_vault,
    module.app_service
  ]
}

# Key Vault access policy for staging slot managed identity
resource "azurerm_key_vault_access_policy" "staging_slot" {
  count = module.app_service.staging_slot_principal_id != null ? 1 : 0

  key_vault_id = module.key_vault.id
  tenant_id    = var.tenant_id
  object_id    = module.app_service.staging_slot_principal_id

  secret_permissions = [
    "Get",
    "List"
  ]

  depends_on = [
    module.key_vault,
    module.app_service
  ]
}

# ============================================================================
# DIAGNOSTIC SETTINGS (AFTER APP SERVICE)
# These depend on app_service being created
# ============================================================================

# Get the workspace ID for diagnostics
locals {
  workspace_id = local.create_workspace ? azurerm_log_analytics_workspace.main[0].id : var.monitoring.log_analytics_workspace_id
}

# Diagnostic Settings for App Service
resource "azurerm_monitor_diagnostic_setting" "app_service" {
  name                       = "diag-appservice-${var.site_name}"
  target_resource_id         = module.app_service.id
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
  enabled_metric {
    category = "AllMetrics"
  }

  depends_on = [module.app_service]
}

# Diagnostic Settings for MySQL
resource "azurerm_monitor_diagnostic_setting" "mysql" {
  name                       = "diag-mysql-${var.site_name}"
  target_resource_id         = module.database.server_id
  log_analytics_workspace_id = local.workspace_id

  # MySQL logs
  enabled_log {
    category = "MySqlSlowLogs"
  }

  enabled_log {
    category = "MySqlAuditLogs"
  }

  # Metrics
  enabled_metric {
    category = "AllMetrics"
  }

  depends_on = [module.database]
}

# ============================================================================
# ALERT RULES (AFTER APP SERVICE)
# ============================================================================

# Alert rules configuration
locals {
  alert_config = {
    http_5xx_threshold   = coalesce(try(var.monitoring.alerts.http_5xx_threshold, null), 10)
    high_cpu_threshold   = coalesce(try(var.monitoring.alerts.high_cpu_threshold, null), 80)
    db_failure_threshold = coalesce(try(var.monitoring.alerts.db_failure_threshold, null), 5)
    alert_window_minutes = coalesce(try(var.monitoring.alerts.alert_window_minutes, null), 5)
  }
}

# Action Group for alerts
resource "azurerm_monitor_action_group" "main" {
  count = length(var.alert_recipients) > 0 ? 1 : 0

  name                = "ag-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = substr(var.site_name, 0, 12)

  dynamic "email_receiver" {
    for_each = var.alert_recipients
    content {
      name          = "email-${email_receiver.key}"
      email_address = email_receiver.value
    }
  }

  tags = local.common_tags
}

# Alert: HTTP 5xx Errors
resource "azurerm_monitor_metric_alert" "http_5xx" {
  count = length(var.alert_recipients) > 0 ? 1 : 0

  name                = "alert-http5xx-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [module.app_service.id]
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

  tags = local.common_tags

  depends_on = [module.app_service]
}

# Alert: High CPU
# Scoped to the App Service Plan (Microsoft.Web/serverfarms) because
# CpuPercentage is a plan-level metric; it does not exist on Web Apps.
resource "azurerm_monitor_metric_alert" "high_cpu" {
  count = length(var.alert_recipients) > 0 ? 1 : 0

  name                = "alert-highcpu-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [module.app_service.plan_id]
  description         = "Alert when CPU exceeds threshold"
  severity            = 2 # Warning
  frequency           = "PT1M"
  window_size         = "PT${local.alert_config.alert_window_minutes}M"

  criteria {
    metric_namespace = "Microsoft.Web/serverfarms"
    metric_name      = "CpuPercentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = local.alert_config.high_cpu_threshold
  }

  action {
    action_group_id = azurerm_monitor_action_group.main[0].id
  }

  tags = local.common_tags

  depends_on = [module.app_service]
}

# Alert: Response Time (MTTD < 5 minutes per spec)
resource "azurerm_monitor_metric_alert" "response_time" {
  count = length(var.alert_recipients) > 0 ? 1 : 0

  name                = "alert-responsetime-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [module.app_service.id]
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

  tags = local.common_tags

  depends_on = [module.app_service]
}

# Front Door Module (conditional)
module "front_door" {
  count  = local.fd_config.enabled ? 1 : 0
  source = "../front-door"

  project_name        = var.project_name
  site_name           = var.site_name
  environment         = var.environment
  resource_group_name = azurerm_resource_group.main.name

  sku_name = local.fd_config.sku_name
  waf_mode = local.fd_config.waf_mode

  origin_hostname = module.app_service.default_hostname
  custom_domain   = var.custom_domain

  cache_uploads_minutes = local.fd_config.cache_uploads_minutes
  cache_static_minutes  = local.fd_config.cache_static_minutes

  tags = local.common_tags

  # Explicit dependency on app_service
  depends_on = [module.app_service]
}

# Diagnostic Settings for Front Door (if enabled)
resource "azurerm_monitor_diagnostic_setting" "front_door" {
  count = local.fd_config.enabled ? 1 : 0

  name                       = "diag-frontdoor-${var.site_name}"
  target_resource_id         = module.front_door[0].profile_id
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
  enabled_metric {
    category = "AllMetrics"
  }

  depends_on = [module.front_door]
}

# ============================================================================
# SECURITY: Update App Service IP Restriction with Front Door ID
# This breaks the circular dependency by updating after Front Door creation
# CRITICAL: Without this, ANY Azure Front Door could access the App Service
# ============================================================================
resource "azapi_update_resource" "app_service_front_door_restriction" {
  count = local.fd_config.enabled ? 1 : 0

  type        = "Microsoft.Web/sites@2023-12-01"
  resource_id = module.app_service.id

  body = {
    properties = {
      siteConfig = {
        ipSecurityRestrictions = [
          {
            ipAddress   = "AzureFrontDoor.Backend"
            action      = "Allow"
            tag         = "ServiceTag"
            priority    = 100
            name        = "AllowFrontDoor"
            description = "Allow traffic only from this specific Front Door instance"
            headers = {
              x-azure-fdid = [module.front_door[0].resource_guid]
            }
          },
          {
            ipAddress   = "Any"
            action      = "Deny"
            priority    = 2147483647
            name        = "Deny all"
            description = "Deny all other traffic"
          }
        ]
        ipSecurityRestrictionsDefaultAction = "Deny"
      }
    }
  }

  depends_on = [
    module.app_service,
    module.front_door
  ]
}

# ============================================================================
# CLOUDFLARE DNS & CDN (conditional - only when cdn_provider = cloudflare)
# Manages DNS records, caching, and WAF rules in Cloudflare
# ============================================================================

module "cloudflare" {
  count  = local.cf_config.enabled ? 1 : 0
  source = "../cloudflare"

  cloudflare_account_id = local.cf_config.account_id
  domain                = local.cf_config.domain
  cdn_provider          = var.cdn_provider

  sites = {
    (var.site_name) = {
      subdomain       = local.cf_config.subdomain
      origin_hostname = module.app_service.default_hostname
      environment     = var.environment
      proxied         = local.cf_config.proxied
    }
  }

  # Azure App Service domain verification token for custom hostname binding
  # Creates TXT record: asuid.<subdomain> -> custom_domain_verification_id
  app_service_verification_tokens = {
    (var.site_name) = module.app_service.custom_domain_verification_id
  }

  enable_waf                     = local.cf_config.enable_waf
  enable_page_rules              = local.cf_config.enable_page_rules
  enable_cache_rules             = local.cf_config.enable_cache_rules
  enable_zone_setting_overrides  = local.cf_config.enable_zone_setting_overrides
  enable_wordpress_optimizations = local.cf_config.enable_wordpress_optimizations

  depends_on = [module.app_service]
}

# ============================================================================
# CUSTOM DOMAIN BINDING
# Binds custom domain to App Service after DNS is configured
# ============================================================================

# Wait for DNS propagation after TXT record creation
# Azure's DNS resolvers may cache negative responses, so we wait 120 seconds
# to ensure the asuid TXT record is resolvable by Azure before binding
# Using triggers to ensure we wait again if DNS records are recreated
resource "time_sleep" "dns_propagation" {
  count = local.cf_config.enabled && !endswith(var.custom_domain, ".azurewebsites.net") ? 1 : 0

  create_duration = "120s"

  # Trigger a new wait whenever DNS records are recreated
  # This is critical because DNS record replacement happens instantly but
  # Azure's resolvers may cache negative responses from previous lookups
  triggers = {
    verification_record_id = try(module.cloudflare[0].app_service_verification_record_ids[var.site_name], "none")
    site_record_id         = try(module.cloudflare[0].site_record_ids[var.site_name], "none")
  }

  depends_on = [module.cloudflare]
}

# Custom hostname binding for the App Service
# This tells Azure to accept traffic for the custom domain
resource "azurerm_app_service_custom_hostname_binding" "main" {
  # Only create if we have a custom domain that's not the default azurewebsites.net
  count = !endswith(var.custom_domain, ".azurewebsites.net") ? 1 : 0

  hostname            = var.custom_domain
  app_service_name    = module.app_service.name
  resource_group_name = local.app_service_resource_group

  # When using Cloudflare proxy (orange cloud), SSL is handled by Cloudflare
  # Azure doesn't need to manage SSL - Cloudflare terminates TLS and proxies to Azure
  # The connection from Cloudflare to Azure uses the *.azurewebsites.net cert

  # Wait for DNS TXT record to propagate before binding
  # The time_sleep resource ensures Azure's resolvers can verify the domain
  depends_on = [
    module.app_service,
    module.cloudflare,
    time_sleep.dns_propagation
  ]

  lifecycle {
    # Ignore changes to ssl_state as it may be modified outside Terraform
    ignore_changes = [ssl_state, thumbprint]

    # Create new binding before destroying old one - ensures continuity
    create_before_destroy = true
  }
}

# ============================================================================
# SITE LIFECYCLE: Soft-Delete Protection
# Resource locks prevent accidental deletion (30-day recovery window via Azure)
# ============================================================================

# Lock the resource group to prevent accidental deletion
# Requires "User Access Administrator" role on the deploying service principal
resource "azurerm_management_lock" "main" {
  count      = var.enable_resource_lock ? 1 : 0
  name       = "site-protection-lock"
  scope      = azurerm_resource_group.main.id
  lock_level = "CanNotDelete"
  notes      = "Protects WordPress site from accidental deletion. 30-day recovery window."
}
