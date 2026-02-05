# App Service Module - Layer 2 Application
# Creates Linux Web App for WordPress with VNet integration
# CRITICAL: NO storage_account block - media via Blob Storage plugin

locals {
  # Short environment suffix for naming
  env_suffix = var.environment == "nonprod" ? "np" : "prod"

  # Resource naming following convention
  name_prefix = "${var.project_name}-${var.site_name}-${local.env_suffix}"

  # Use provided plan or create new
  # IMPORTANT: use_shared_plan must be explicitly set when using a shared plan
  # to avoid "count depends on unknown value" errors during initial deployment
  # Uses ternary operator for short-circuit evaluation (avoids evaluating plan_id == null when use_shared_plan is true)
  create_plan = var.use_shared_plan ? false : (var.plan_id == null)
  plan_id     = local.create_plan ? azurerm_service_plan.main[0].id : var.plan_id

  # Check if SKU supports staging slots (Standard and Premium only, not Basic)
  # Basic tier (B1, B2, B3) does NOT support deployment slots
  sku_supports_slots = !startswith(var.sku_name, "B")

  # WordPress container image from MCR
  docker_image = "mcr.microsoft.com/appsvc/wordpress-debian-php:${var.docker_image_tag}"

  # CDN provider detection (support both new cdn_provider and legacy front_door_enabled)
  # Priority: cdn_provider > front_door_enabled
  effective_cdn_provider = var.cdn_provider != "none" ? var.cdn_provider : (var.front_door_enabled ? "azure_front_door" : "direct")

  # Cloudflare IPv4 ranges (from https://www.cloudflare.com/ips/)
  cloudflare_ipv4_ranges = [
    "173.245.48.0/20",
    "103.21.244.0/22",
    "103.22.200.0/22",
    "103.31.4.0/22",
    "141.101.64.0/18",
    "108.162.192.0/18",
    "190.93.240.0/20",
    "188.114.96.0/20",
    "197.234.240.0/22",
    "198.41.128.0/17",
    "162.158.0.0/15",
    "104.16.0.0/13",
    "104.24.0.0/14",
    "172.64.0.0/13",
    "131.0.72.0/22"
  ]

  # Cloudflare IPv6 ranges (from https://www.cloudflare.com/ips/)
  cloudflare_ipv6_ranges = [
    "2400:cb00::/32",
    "2606:4700::/32",
    "2803:f800::/32",
    "2405:b500::/32",
    "2405:8100::/32",
    "2a06:98c0::/29",
    "2c0f:f248::/32"
  ]

  # App settings for WordPress
  # IMPORTANT: Microsoft's WordPress container uses DATABASE_* not WORDPRESS_DB_*
  # See: https://github.com/Azure/wordpress-linux-appservice/blob/main/WordPress/using_an_existing_mysql_database.md
  app_settings = {
    # Database configuration (Microsoft WordPress container format)
    "DATABASE_HOST"     = var.database_host
    "DATABASE_NAME"     = var.database_name
    "DATABASE_USERNAME" = var.database_username
    "DATABASE_PASSWORD" = "@Microsoft.KeyVault(SecretUri=${var.database_password_secret_uri})"

    # WordPress URLs - STICKY to deployment slot
    "WP_HOME"    = "https://${var.custom_domain}"
    "WP_SITEURL" = "https://${var.custom_domain}"

    # Azure Storage for media uploads (NO mount - plugin-based)
    "MICROSOFT_AZURE_ACCOUNT_NAME" = var.storage_account_name
    "MICROSOFT_AZURE_CONTAINER"    = var.storage_container_name
    "MICROSOFT_AZURE_ACCOUNT_KEY"  = "@Microsoft.KeyVault(SecretUri=${var.storage_access_key_secret_uri})"

    # Application Insights (if configured)
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = var.app_insights_connection_string_secret_uri != "" ? "@Microsoft.KeyVault(SecretUri=${var.app_insights_connection_string_secret_uri})" : ""

    # App Service storage - required for WordPress container
    "WEBSITES_ENABLE_APP_SERVICE_STORAGE" = "true"

    # DNS configuration for private endpoint resolution
    # Required when using VNet integration with private MySQL
    "WEBSITE_DNS_SERVER" = "168.63.129.16"

    # PHP configuration
    "PHP_MEMORY_LIMIT"       = "256M"
    "PHP_MAX_EXECUTION_TIME" = "120"
    "PHP_MAX_INPUT_VARS"     = "2000"

    # WordPress security
    "DISABLE_WP_CRON" = "true" # Use Azure Functions for cron

    # Debugging (nonprod only)
    "WP_DEBUG" = var.environment == "nonprod" ? "true" : "false"
  }

  # Sticky settings - these stay with the slot, not swapped
  sticky_settings = [
    "WP_HOME",
    "WP_SITEURL",
    "WP_DEBUG"
  ]
}

# App Service Plan (created if not using shared plan)
resource "azurerm_service_plan" "main" {
  count = local.create_plan ? 1 : 0

  name                = "asp-${local.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  os_type             = "Linux"
  sku_name            = var.sku_name
  worker_count        = var.worker_count

  tags = merge(var.tags, {
    Site = var.site_name
  })
}

# Linux Web App for WordPress
resource "azurerm_linux_web_app" "main" {
  name                = "app-${local.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  service_plan_id     = local.plan_id

  # Security settings
  https_only = true

  # VNet integration for database access
  virtual_network_subnet_id = var.app_subnet_id

  # Managed identity for Key Vault access
  identity {
    type = "SystemAssigned"
  }

  # Site configuration
  site_config {
    always_on                         = var.always_on
    minimum_tls_version               = "1.2"
    http2_enabled                     = true
    ftps_state                        = "Disabled"
    health_check_path                 = var.health_check_path
    health_check_eviction_time_in_min = 5
    vnet_route_all_enabled            = true

    # Container configuration
    application_stack {
      docker_registry_url = "https://mcr.microsoft.com"
      docker_image_name   = "appsvc/wordpress-debian-php:${var.docker_image_tag}"
    }

    # =========================================================================
    # IP RESTRICTIONS based on cdn_provider
    # =========================================================================
    # cloudflare: Allow only Cloudflare IP ranges
    # azure_front_door: Allow only Azure Front Door service tag with x-azure-fdid header
    # direct/none: Allow all traffic
    #
    # NOTE: When using azure_front_door, the x_azure_fdid header is intentionally
    # empty here. The composition layer uses azapi_update_resource to add the
    # specific Front Door resource_guid AFTER Front Door is created.
    # =========================================================================

    # Azure Health Probe - MUST be allowed for App Service health checks to work
    # This is Azure's internal health monitoring service IP
    # Priority 10 ensures it's evaluated before CDN restrictions
    ip_restriction {
      ip_address = "168.63.129.16/32"
      name       = "AllowAzureHealthProbe"
      priority   = 10
      action     = "Allow"
    }

    # Cloudflare IPv4 restrictions (when cdn_provider = cloudflare)
    dynamic "ip_restriction" {
      for_each = local.effective_cdn_provider == "cloudflare" ? local.cloudflare_ipv4_ranges : []
      content {
        ip_address = ip_restriction.value
        name       = "AllowCloudflare-IPv4-${index(local.cloudflare_ipv4_ranges, ip_restriction.value)}"
        priority   = 100 + index(local.cloudflare_ipv4_ranges, ip_restriction.value)
        action     = "Allow"
      }
    }

    # Cloudflare IPv6 restrictions (when cdn_provider = cloudflare)
    dynamic "ip_restriction" {
      for_each = local.effective_cdn_provider == "cloudflare" ? local.cloudflare_ipv6_ranges : []
      content {
        ip_address = ip_restriction.value
        name       = "AllowCloudflare-IPv6-${index(local.cloudflare_ipv6_ranges, ip_restriction.value)}"
        priority   = 200 + index(local.cloudflare_ipv6_ranges, ip_restriction.value)
        action     = "Allow"
      }
    }

    # Azure Front Door restriction (when cdn_provider = azure_front_door)
    dynamic "ip_restriction" {
      for_each = local.effective_cdn_provider == "azure_front_door" ? [1] : []
      content {
        service_tag = "AzureFrontDoor.Backend"
        name        = "AllowFrontDoor"
        priority    = 100
        action      = "Allow"
        headers {
          x_azure_fdid = var.front_door_id != "" ? [var.front_door_id] : []
        }
      }
    }

    # Default action: Deny when using CDN (cloudflare or azure_front_door), Allow otherwise
    ip_restriction_default_action = local.effective_cdn_provider != "direct" ? "Deny" : "Allow"
  }

  # App settings
  app_settings = local.app_settings

  # Sticky settings for deployment slots
  sticky_settings {
    app_setting_names = local.sticky_settings
  }

  # NOTE: NO storage_account block
  # Media uploads handled via Azure Blob Storage plugin
  # This avoids the 2-3 second latency from Azure Files mounts

  # Logging configuration (CKV_AZURE_63, CKV_AZURE_65, CKV_AZURE_66)
  logs {
    detailed_error_messages = true
    failed_request_tracing  = true

    http_logs {
      file_system {
        retention_in_days = 7
        retention_in_mb   = 35
      }
    }
  }

  tags = merge(var.tags, {
    Site = var.site_name
  })

  lifecycle {
    # IMPORTANT: App Service names are globally unique in Azure
    # When changing resource_group, the old app must be deleted BEFORE
    # the new one can be created with the same name
    create_before_destroy = false

    ignore_changes = [
      # Ignore changes made by WordPress admin
      app_settings["WORDPRESS_CONFIG_EXTRA"]
    ]
  }
}

# Staging Deployment Slot
# Only create for Standard (S*) and Premium (P*) SKUs - Basic tier doesn't support slots
resource "azurerm_linux_web_app_slot" "staging" {
  count = local.sku_supports_slots ? 1 : 0

  name           = "staging"
  app_service_id = azurerm_linux_web_app.main.id

  # Security settings
  https_only = true

  # VNet integration
  virtual_network_subnet_id = var.app_subnet_id

  # Managed identity
  identity {
    type = "SystemAssigned"
  }

  # Site configuration (same as production)
  site_config {
    always_on                         = var.always_on
    minimum_tls_version               = "1.2"
    http2_enabled                     = true
    ftps_state                        = "Disabled"
    health_check_path                 = var.health_check_path
    health_check_eviction_time_in_min = 5
    vnet_route_all_enabled            = true

    application_stack {
      docker_registry_url = "https://mcr.microsoft.com"
      docker_image_name   = "appsvc/wordpress-debian-php:${var.docker_image_tag}"
    }
  }

  # Staging-specific settings (WP_HOME/WP_SITEURL are sticky)
  app_settings = merge(local.app_settings, {
    "WP_HOME"    = "https://app-${local.name_prefix}-staging.azurewebsites.net"
    "WP_SITEURL" = "https://app-${local.name_prefix}-staging.azurewebsites.net"
    "WP_DEBUG"   = "true" # Always debug in staging
  })

  tags = merge(var.tags, {
    Site = var.site_name
    Slot = "staging"
  })
}

# Auto-scale settings (at plan level)
resource "azurerm_monitor_autoscale_setting" "main" {
  count = local.create_plan ? 1 : 0

  name                = "autoscale-${local.name_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  target_resource_id  = azurerm_service_plan.main[0].id

  profile {
    name = "default"

    capacity {
      default = var.worker_count
      minimum = 1
      maximum = 5
    }

    # Scale out on high CPU
    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.main[0].id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 70
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT10M"
      }
    }

    # Scale out on high memory
    rule {
      metric_trigger {
        metric_name        = "MemoryPercentage"
        metric_resource_id = azurerm_service_plan.main[0].id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 80
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT10M"
      }
    }

    # Scale in when metrics low
    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.main[0].id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT15M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 50
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT15M"
      }
    }
  }

  tags = merge(var.tags, {
    Site = var.site_name
  })
}
