# App Service Module - Layer 2 Application
# Creates Linux Web App for WordPress with VNet integration
# CRITICAL: NO storage_account block - media stays on /home (see the app settings below)

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

  # Deployment slots exist on Standard (S*) and Premium (P*/Pv2/Pv3) only. Free (F1),
  # Shared (D1) and Basic (B1-B3) have none. Allow-list rather than deny-list so an
  # unrecognised or newly added tier fails closed (no slot) instead of erroring at apply.
  # NOTE: var.sku_name's validation regex admits only B*/S*/P*, so today this is defence
  # in depth - it keeps the guard correct if that regex is ever widened.
  sku_supports_slots = can(regex("^(S|P)[0-9]", var.sku_name))

  # The slot exists only when the SKU supports one AND the caller has not opted out.
  # staging_slot_enabled defaults to true, so every earlier release's plan is unchanged.
  create_staging_slot = local.sku_supports_slots && var.staging_slot_enabled

  # CDN provider detection (support both new cdn_provider and legacy front_door_enabled)
  # Priority: cdn_provider > front_door_enabled
  effective_cdn_provider = var.cdn_provider != "none" ? var.cdn_provider : (var.front_door_enabled ? "azure_front_door" : "direct")

  # Cloudflare IPv4 ranges — uses live-fetched list when passed from composition module,
  # falls back to the static list for standalone use or when cdn_provider != cloudflare.
  # Fallback source: https://www.cloudflare.com/ips/
  cloudflare_ipv4_ranges = var.cloudflare_ipv4_cidr_blocks != null ? var.cloudflare_ipv4_cidr_blocks : [
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

  # Cloudflare IPv6 ranges — same live-fetch / fallback pattern as IPv4.
  # Fallback source: https://www.cloudflare.com/ips/
  cloudflare_ipv6_ranges = var.cloudflare_ipv6_cidr_blocks != null ? var.cloudflare_ipv6_cidr_blocks : [
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
  app_settings_base = {
    # Database configuration (Microsoft WordPress container format)
    "DATABASE_HOST"     = var.database_host
    "DATABASE_NAME"     = var.database_name
    "DATABASE_USERNAME" = var.database_username
    "DATABASE_PASSWORD" = "@Microsoft.KeyVault(SecretUri=${var.database_password_secret_uri})"

    # WordPress URLs - STICKY to deployment slot
    "WP_HOME"    = "https://${var.custom_domain}"
    "WP_SITEURL" = "https://${var.custom_domain}"

    # Application Insights (if configured)
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = var.app_insights_connection_string_secret_uri != "" ? "@Microsoft.KeyVault(SecretUri=${var.app_insights_connection_string_secret_uri})" : ""

    # App Service storage - required for WordPress container
    "WEBSITES_ENABLE_APP_SERVICE_STORAGE" = "true"

    # DNS configuration for private endpoint resolution
    # Required when using VNet integration with private MySQL
    "WEBSITE_DNS_SERVER" = "168.63.129.16"

    # PHP configuration.
    #
    # PHP_MEMORY_LIMIT is the real (prefixed) name and IS read by the container:
    # documented default 512M, "can only be decreased". 256M is DELIBERATE - one
    # B1/S1 plan (1.75 GB) carries two sites plus staging slots, so 512M per PHP
    # worker widens the OOM blast radius on shared compute. Consumers on a larger
    # plan can raise it via extra_app_settings.
    "PHP_MEMORY_LIMIT" = "256M"

    # These two take NO prefix - the container reads MAX_EXECUTION_TIME and
    # MAX_INPUT_VARS. The PHP_-prefixed names this module used through v3.0.0 were
    # inert; the container never read them. Both are now pinned at the documented
    # default, which is also the documented maximum ("can only be decreased"), so
    # they are explicit no-ops rather than tuning knobs. Do NOT carry the old
    # PHP_MAX_INPUT_VARS value of 2000 across: against the real default of 10000
    # that is an 80% cut, and PHP truncates over-limit POSTs silently. max_input_vars
    # is INI_PERDIR, so a plugin cannot recover from it with ini_set() at runtime.
    "MAX_EXECUTION_TIME" = "120"   # default 120, max 120
    "MAX_INPUT_VARS"     = "10000" # default 10000, max 10000

    # WordPress cron - use built-in wp-cron.php (triggered on page loads)
    # Set to "true" only after provisioning an external cron replacement (Azure Functions, etc.)
    "DISABLE_WP_CRON" = "false"

    # Debugging (nonprod only)
    "WP_DEBUG" = var.environment == "nonprod" ? "true" : "false"
  }

  # Settings named for the Microsoft Azure Storage for WordPress plugin, which reads them
  # as wp-config.php constants. The image does not read them, so without that plugin
  # installed they are inert - and the storage account key still sits in the app's
  # environment. storage_plugin_app_settings_enabled = false drops them. A filtered for
  # expression rather than a conditional, whose two map shapes would not unify.
  storage_plugin_app_settings = {
    for name, value in {
      "MICROSOFT_AZURE_ACCOUNT_NAME" = var.storage_account_name
      "MICROSOFT_AZURE_CONTAINER"    = var.storage_container_name
      "MICROSOFT_AZURE_ACCOUNT_KEY"  = "@Microsoft.KeyVault(SecretUri=${var.storage_access_key_secret_uri})"
    } : name => value if var.storage_plugin_app_settings_enabled
  }

  app_settings = merge(local.app_settings_base, local.storage_plugin_app_settings)

  # Passwordless database access, stages 2 and 3. These apply to the PRODUCTION app only:
  # the staging slot keeps local.app_settings as it was, password settings included, so it
  # still reaches the database with the password until a later release gives it an identity.
  # The image reads ENABLE_MYSQL_MANAGED_IDENTITY at request time and swaps its password
  # login for a token login; no file in the container changes. A filtered for expression
  # rather than a conditional, whose two map shapes would not unify.
  mysql_managed_identity_app_settings = {
    for name, value in {
      "ENABLE_MYSQL_MANAGED_IDENTITY" = "true"
      "ENTRA_CLIENT_ID"               = var.mysql_managed_identity_client_id
      "DATABASE_USERNAME"             = var.mysql_managed_identity_database_user
    } : name => value if var.mysql_managed_identity_enabled
  }

  # Stage 3 removes DATABASE_PASSWORD from the production app. The Key Vault secret is
  # untouched: the way back needs it.
  production_app_settings = merge(
    {
      for name, value in local.app_settings : name => value
      if name != "DATABASE_PASSWORD" || var.database_password_app_setting_enabled
    },
    local.mysql_managed_identity_app_settings
  )

  # With a slot, the managed-identity names are sticky so a swap leaves each side's own
  # database login where it is: production keeps the token settings, the slot keeps the
  # password settings. DATABASE_PASSWORD is listed too, because stage 3 leaves it only on the
  # slot. Nothing is added while the switch is off or there is no slot.
  mysql_managed_identity_sticky_names = var.mysql_managed_identity_enabled && local.create_staging_slot ? [
    "ENABLE_MYSQL_MANAGED_IDENTITY",
    "ENTRA_CLIENT_ID",
    "DATABASE_USERNAME",
    "DATABASE_PASSWORD"
  ] : []

  # Sticky settings - these stay with the slot, not swapped
  sticky_settings = distinct(concat([
    "WP_HOME",
    "WP_SITEURL",
    "WP_DEBUG"
  ], local.mysql_managed_identity_sticky_names, var.extra_sticky_app_setting_names))
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
  # always_on defaults to true at every layer; Checkov cannot resolve the optional()
  # attribute of the site module's app_service object that supplies it.
  #checkov:skip=CKV_AZURE_214:always_on defaults to true through an optional() attribute Checkov cannot resolve
  name                = "app-${local.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  service_plan_id     = local.plan_id

  # Security settings
  https_only = true

  # Publishing credentials. Both default to true, matching the azurerm provider
  # default; azurerm only calls the API when the value is false, so `true` is a
  # true no-op. The two ARM policies are independent - disabling webdeploy stops
  # FTP/S *deployment* from working but does not flip the FTP flag, so harden both
  # explicitly. Disabling webdeploy also breaks zip_deploy_file. See README.
  ftp_publish_basic_authentication_enabled       = var.ftp_publish_basic_authentication_enabled
  webdeploy_publish_basic_authentication_enabled = var.webdeploy_publish_basic_authentication_enabled

  # VNet integration for database access
  virtual_network_subnet_id = var.app_subnet_id

  # Custom backup and restore over that VNet integration, so the backup target can
  # keep denying public access (the app subnet is allow-listed). null, not false, when
  # the backup is off: it leaves the provider default in place, so a plan without a
  # backup is byte-for-byte what it was.
  virtual_network_backup_restore_enabled = var.backup_enabled ? true : null

  # Managed identity for Key Vault access. The system-assigned identity stays: it resolves
  # the Key Vault references, because key_vault_reference_identity_id is left unset. A
  # user-assigned identity (the database login, stage 1) is attached to this app only.
  identity {
    type         = length(var.user_assigned_identity_ids) > 0 ? "SystemAssigned, UserAssigned" : "SystemAssigned"
    identity_ids = length(var.user_assigned_identity_ids) > 0 ? var.user_assigned_identity_ids : null
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
        name       = "AllowCloudflare-IPv4-${ip_restriction.key}"
        priority   = 100 + ip_restriction.key
        action     = "Allow"
        dynamic "headers" {
          for_each = var.cdn_origin_header_name == null ? [] : [var.cdn_origin_header_name]
          content {
            x_azure_fdid     = headers.value == "x_azure_fdid" ? var.cdn_origin_header_values : null
            x_forwarded_host = headers.value == "x_forwarded_host" ? var.cdn_origin_header_values : null
          }
        }
      }
    }

    # Cloudflare IPv6 restrictions (when cdn_provider = cloudflare)
    dynamic "ip_restriction" {
      for_each = local.effective_cdn_provider == "cloudflare" ? local.cloudflare_ipv6_ranges : []
      content {
        ip_address = ip_restriction.value
        name       = "AllowCloudflare-IPv6-${ip_restriction.key}"
        priority   = 200 + ip_restriction.key
        action     = "Allow"
        dynamic "headers" {
          for_each = var.cdn_origin_header_name == null ? [] : [var.cdn_origin_header_name]
          content {
            x_azure_fdid     = headers.value == "x_azure_fdid" ? var.cdn_origin_header_values : null
            x_forwarded_host = headers.value == "x_forwarded_host" ? var.cdn_origin_header_values : null
          }
        }
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

    # =========================================================================
    # SCM/KUDU IP RESTRICTIONS - a SEPARATE gate from the rules above
    # =========================================================================
    # scm_use_main_ip_restriction is intentionally left at the provider default
    # (false). Inheriting the main rules would admit only Cloudflare/Front Door
    # and lock Kudu out from every operator address - including the SSH console
    # that is the only route to a manual `wp core update --major`. See README.
    #
    # No health-probe rule is needed here: 168.63.129.16/32 probes the main site,
    # never SCM.
    dynamic "scm_ip_restriction" {
      for_each = var.scm_ip_restrictions
      content {
        ip_address                = scm_ip_restriction.value.ip_address
        service_tag               = scm_ip_restriction.value.service_tag
        virtual_network_subnet_id = scm_ip_restriction.value.virtual_network_subnet_id
        name                      = coalesce(scm_ip_restriction.value.name, "ScmRule-${scm_ip_restriction.key}")
        priority                  = coalesce(scm_ip_restriction.value.priority, 100 + scm_ip_restriction.key)
        action                    = scm_ip_restriction.value.action
        description               = scm_ip_restriction.value.description
      }
    }

    scm_ip_restriction_default_action = var.scm_ip_restriction_default_action
  }

  # App settings (default WordPress settings merged with extra settings from consumer)
  app_settings = merge(local.production_app_settings, var.extra_app_settings)

  # Sticky settings for deployment slots
  sticky_settings {
    app_setting_names       = local.sticky_settings
    connection_string_names = length(var.sticky_connection_string_names) > 0 ? var.sticky_connection_string_names : null
  }

  # Scheduled custom backup of this app only; the staging slot below has none. The SAS
  # URL is sensitive in the provider schema and in the variable, and never an output.
  dynamic "backup" {
    for_each = var.backup_enabled ? [1] : []
    content {
      name                = "backup-${local.name_prefix}"
      enabled             = true
      storage_account_url = var.backup_storage_account_url

      schedule {
        frequency_interval       = var.backup_frequency_interval
        frequency_unit           = var.backup_frequency_unit
        keep_at_least_one_backup = var.backup_keep_at_least_one_backup
        retention_period_days    = var.backup_retention_period_days
        start_time               = var.backup_start_time
      }
    }
  }

  # NOTE: NO storage_account block
  # Media stays on /home; the MICROSOFT_AZURE_* app settings above only configure an optional plugin
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

    precondition {
      condition     = var.cdn_origin_header_name == null || (local.effective_cdn_provider == "cloudflare" && length(var.cdn_origin_header_values) >= 1 && length(var.cdn_origin_header_values) <= 8)
      error_message = "cdn_origin_header_name applies only to the Cloudflare allow rules: set cdn_provider = \"cloudflare\" and give cdn_origin_header_values 1 to 8 values, or leave the name null."
    }

    # A conditional, so the sensitive URL is only read when the backup is on. Unknown
    # at plan on a first deployment (the composition's SAS is read at apply then), in
    # which case Terraform checks it at apply.
    precondition {
      condition     = var.backup_enabled ? var.backup_storage_account_url != null : true
      error_message = "backup_enabled is true, so backup_storage_account_url must carry the container SAS URL."
    }

    # App Service allows one custom backup every 2 hours at most. A precondition, not a
    # variable validation: a cross-variable validation needs Terraform 1.9, and this
    # module supports 1.6.
    precondition {
      condition     = var.backup_frequency_unit == "Hour" ? var.backup_frequency_interval >= 2 : true
      error_message = "backup_frequency_interval must be at least 2 when backup_frequency_unit is \"Hour\": App Service allows one custom backup every 2 hours at most."
    }

    # Stage 2 sets a client ID and a user for the token login, and the app needs the identity
    # that owns that client ID.
    precondition {
      condition     = !var.mysql_managed_identity_enabled || (var.mysql_managed_identity_client_id != null && var.mysql_managed_identity_database_user != null && length(var.user_assigned_identity_ids) > 0)
      error_message = "mysql_managed_identity_enabled is true, so mysql_managed_identity_client_id, mysql_managed_identity_database_user and user_assigned_identity_ids must all be set."
    }

    # Leaving the password off with the token login still off would leave the app with no
    # way to reach the database.
    precondition {
      condition     = var.database_password_app_setting_enabled || var.mysql_managed_identity_enabled
      error_message = "database_password_app_setting_enabled = false requires mysql_managed_identity_enabled = true: without the token login the app would have no database credentials."
    }

    ignore_changes = [
      # Ignore changes made by WordPress admin
      app_settings["WORDPRESS_CONFIG_EXTRA"]
    ]
  }
}

# Staging Deployment Slot
# Only create for Standard (S*) and Premium (P*) SKUs - Basic tier doesn't support slots -
# and only while staging_slot_enabled is true (the default).
resource "azurerm_linux_web_app_slot" "staging" {
  count = local.create_staging_slot ? 1 : 0

  name           = "staging"
  app_service_id = azurerm_linux_web_app.main.id

  # Security settings
  https_only = true

  # The slot carries its OWN publishing-credential flags. A hardening change that
  # misses the slot still reads as compliant on the site resource alone.
  ftp_publish_basic_authentication_enabled       = var.ftp_publish_basic_authentication_enabled
  webdeploy_publish_basic_authentication_enabled = var.webdeploy_publish_basic_authentication_enabled

  # VNet integration
  virtual_network_subnet_id = var.app_subnet_id

  # Azure sets backup/restore over the VNet per slot, so the slot gets the same flag as
  # the app whenever the backup is on (a restore into this slot then reaches the
  # account under Deny). The slot gets no backup schedule. null, not false, when the
  # backup is off, so earlier plans are unchanged.
  virtual_network_backup_restore_enabled = var.backup_enabled ? true : null

  # Managed identity
  identity {
    type = "SystemAssigned"
  }

  # Site configuration (staging may differ from production for cost savings)
  site_config {
    always_on                         = var.staging_always_on
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

    ip_restriction {
      ip_address = "168.63.129.16/32"
      name       = "AllowAzureHealthProbe"
      priority   = 10
      action     = "Allow"
    }

    dynamic "ip_restriction" {
      for_each = local.effective_cdn_provider == "cloudflare" ? local.cloudflare_ipv4_ranges : []
      content {
        ip_address = ip_restriction.value
        name       = "AllowCloudflare-IPv4-${ip_restriction.key}"
        priority   = 100 + ip_restriction.key
        action     = "Allow"
        dynamic "headers" {
          for_each = var.cdn_origin_header_name == null ? [] : [var.cdn_origin_header_name]
          content {
            x_azure_fdid     = headers.value == "x_azure_fdid" ? var.cdn_origin_header_values : null
            x_forwarded_host = headers.value == "x_forwarded_host" ? var.cdn_origin_header_values : null
          }
        }
      }
    }

    dynamic "ip_restriction" {
      for_each = local.effective_cdn_provider == "cloudflare" ? local.cloudflare_ipv6_ranges : []
      content {
        ip_address = ip_restriction.value
        name       = "AllowCloudflare-IPv6-${ip_restriction.key}"
        priority   = 200 + ip_restriction.key
        action     = "Allow"
        dynamic "headers" {
          for_each = var.cdn_origin_header_name == null ? [] : [var.cdn_origin_header_name]
          content {
            x_azure_fdid     = headers.value == "x_azure_fdid" ? var.cdn_origin_header_values : null
            x_forwarded_host = headers.value == "x_forwarded_host" ? var.cdn_origin_header_values : null
          }
        }
      }
    }

    # TODO: The staging slot restricts to AzureFrontDoor.Backend service tag but cannot
    # enforce the per-instance x-azure-fdid header check. front_door_id is intentionally
    # not passed to this module (see wordpress-site/main.tf) to avoid a circular dependency;
    # the azapi_update_resource that patches the FDID only targets the main app slot.
    # Staging is lower-risk (not publicly advertised), but be aware any Front Door instance
    # can reach this slot when cdn_provider = azure_front_door.
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

    ip_restriction_default_action = local.effective_cdn_provider != "direct" ? "Deny" : "Allow"

    # SCM/Kudu restrictions for the slot. The slot has its own SCM endpoint at
    # <app>-staging.scm.azurewebsites.net, so it needs the same treatment as the
    # main app. Same rules are applied to both.
    dynamic "scm_ip_restriction" {
      for_each = var.scm_ip_restrictions
      content {
        ip_address                = scm_ip_restriction.value.ip_address
        service_tag               = scm_ip_restriction.value.service_tag
        virtual_network_subnet_id = scm_ip_restriction.value.virtual_network_subnet_id
        name                      = coalesce(scm_ip_restriction.value.name, "ScmRule-${scm_ip_restriction.key}")
        priority                  = coalesce(scm_ip_restriction.value.priority, 100 + scm_ip_restriction.key)
        action                    = scm_ip_restriction.value.action
        description               = scm_ip_restriction.value.description
      }
    }

    scm_ip_restriction_default_action = var.scm_ip_restriction_default_action
  }

  # Staging-specific settings (WP_HOME/WP_SITEURL are sticky)
  app_settings = merge(local.app_settings, var.extra_app_settings, {
    "WP_HOME"    = "https://app-${local.name_prefix}-staging.azurewebsites.net"
    "WP_SITEURL" = "https://app-${local.name_prefix}-staging.azurewebsites.net"
    "WP_DEBUG"   = "true" # Always debug in staging
  }, var.staging_app_settings_override)

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
