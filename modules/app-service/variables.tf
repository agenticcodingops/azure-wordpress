# App Service Module Variables
# Layer 2 Application - Linux Web App for WordPress

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
    condition     = can(regex("^[a-z0-9-]+$", var.site_name))
    error_message = "Site name must contain only lowercase letters, numbers, and hyphens."
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
  description = "Azure region for resources"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "app_subnet_id" {
  description = "ID of the App Service VNet integration subnet (from networking module)"
  type        = string
}

# App Service Plan configuration
variable "plan_id" {
  description = "ID of existing App Service Plan. If null, a new plan is created."
  type        = string
  default     = null
}

variable "use_shared_plan" {
  description = "Set to true when using a shared App Service Plan. This avoids plan-time unknown value issues."
  type        = bool
  default     = false
}

variable "sku_name" {
  description = "App Service Plan SKU (P1v3 recommended for production)"
  type        = string
  default     = "P1v3"

  validation {
    condition     = can(regex("^(B|S|P)[0-9]v?[0-9]?$", var.sku_name))
    error_message = "SKU must be a valid App Service Plan SKU (e.g., B1, S1, P1v3)."
  }
}

variable "always_on" {
  description = "Keep the app always loaded (required for production)"
  type        = bool
  default     = true
}

variable "health_check_path" {
  description = "Path for health check endpoint (use a lightweight static file, not the homepage)"
  type        = string
  default     = "/wp-includes/images/blank.gif"
}

variable "worker_count" {
  description = "Number of workers (instances)"
  type        = number
  default     = 1

  validation {
    condition     = var.worker_count >= 1 && var.worker_count <= 30
    error_message = "Worker count must be between 1 and 30."
  }
}

# WordPress container configuration
variable "docker_image_tag" {
  description = "Tag of Microsoft's WordPress container image (appsvc/wordpress-debian-php): the PHP version, not a WordPress version. Floating tags exist for 8.2 and 8.3 only; the 8.4 series is published as dated tags (for example 8.4_20260922.3.tuxprod), so \"8.4\" alone does not exist on the registry. A dated tag (8.x_YYYYMMDD.N.tuxprod) disables automatic platform image updates, which makes image patching the consumer's job."
  type        = string
  default     = "8.3"
}

# Database connection
variable "database_host" {
  description = "MySQL server FQDN"
  type        = string
}

variable "database_name" {
  description = "MySQL database name"
  type        = string
}

variable "database_username" {
  description = "MySQL username"
  type        = string
  sensitive   = true
}

# Key Vault reference for database password
variable "key_vault_uri" {
  description = "Key Vault URI for secret references"
  type        = string
}

variable "database_password_secret_uri" {
  description = "Key Vault secret URI for database password (versionless)"
  type        = string
}

# Storage configuration (for WordPress media offload)
variable "storage_account_name" {
  description = "Storage account name for media uploads"
  type        = string
}

variable "storage_container_name" {
  description = "Storage container name for media uploads"
  type        = string
}

variable "storage_access_key_secret_uri" {
  description = "Key Vault secret URI for storage access key (versionless)"
  type        = string
}

# Custom domain
variable "custom_domain" {
  description = "Custom domain for the WordPress site"
  type        = string
}

# App Insights connection
variable "app_insights_connection_string_secret_uri" {
  description = "Key Vault secret URI for App Insights connection string (versionless)"
  type        = string
  default     = ""
}

variable "front_door_enabled" {
  description = "DEPRECATED: Use cdn_provider instead. Whether Front Door is enabled."
  type        = bool
  default     = true
}

variable "cdn_provider" {
  description = "CDN provider for IP restrictions: 'cloudflare', 'azure_front_door', 'direct', or 'none'"
  type        = string
  default     = "none"

  validation {
    condition     = contains(["cloudflare", "azure_front_door", "direct", "none"], var.cdn_provider)
    error_message = "CDN provider must be 'cloudflare', 'azure_front_door', 'direct', or 'none'."
  }
}

variable "cdn_origin_header_name" {
  description = "Request header that every CDN allow rule must also match, on the app and its staging slot: \"x_azure_fdid\" or \"x_forwarded_host\". null (the default) keeps IP-only rules."
  type        = string
  default     = null

  validation {
    condition     = var.cdn_origin_header_name == null ? true : contains(["x_azure_fdid", "x_forwarded_host"], var.cdn_origin_header_name)
    error_message = "cdn_origin_header_name must be null, \"x_azure_fdid\" or \"x_forwarded_host\"."
  }
}

variable "cdn_origin_header_values" {
  description = "Values accepted in the CDN origin header: 1 to 8 (Azure's per-header limit), so a rotation can accept the old and new values together. UUIDs are required for x_azure_fdid. Treat them as secrets."
  type        = list(string)
  default     = []
  sensitive   = true
}

variable "front_door_id" {
  description = "Azure Front Door resource GUID (required when cdn_provider = azure_front_door)"
  type        = string
  default     = ""
}

# SCM/Kudu network posture.
#
# The SCM endpoint (<app>.scm.azurewebsites.net) is a SEPARATE gate from the
# ip_restriction rules driven by cdn_provider, and azurerm defaults it to "Allow".
# Kudu offers a shell and read/write over the persisted /home of this app AND its
# staging slot, so a site whose public plane admits only Cloudflare still has an
# internet-reachable Kudu, protected by credentials alone.
#
# Note the provider default is a schema-level Default, not "leave Azure alone":
# omitting these arguments materialises "Allow" into state and reverts any
# out-of-band drift to "Deny" on the next apply.
#
# scm_use_main_ip_restriction is deliberately NOT exposed - see README.

variable "scm_ip_restrictions" {
  description = "Allow-list for the SCM/Kudu endpoint. Exactly one of ip_address, service_tag or virtual_network_subnet_id must be set per entry. Empty (the default) preserves current provider behaviour."
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

  # azurerm enforces this mutual exclusion inside ExpandIpRestrictions at APPLY
  # time, so without this a malformed entry plans clean and dies mid-apply.
  validation {
    condition = alltrue([
      for r in var.scm_ip_restrictions :
      length([for v in [r.ip_address, r.service_tag, r.virtual_network_subnet_id] : v if v != null && v != ""]) == 1
    ])
    error_message = "Each scm_ip_restrictions entry must set exactly one of ip_address, service_tag, or virtual_network_subnet_id."
  }

  validation {
    condition     = alltrue([for r in var.scm_ip_restrictions : contains(["Allow", "Deny"], r.action)])
    error_message = "SCM IP restriction action must be 'Allow' or 'Deny'."
  }
}

variable "scm_ip_restriction_default_action" {
  description = "Default action for SCM/Kudu traffic matching no scm_ip_restrictions entry. Defaults to 'Allow', matching the azurerm provider default, so existing consumers see no plan diff. Set to 'Deny' to close Kudu to everything not allow-listed."
  type        = string
  default     = "Allow"

  validation {
    condition     = contains(["Allow", "Deny"], var.scm_ip_restriction_default_action)
    error_message = "SCM IP restriction default action must be 'Allow' or 'Deny'."
  }
}

variable "ftp_publish_basic_authentication_enabled" {
  description = "Enable basic authentication for FTP publishing. Defaults to true, matching the azurerm provider default. Note site_config.ftps_state is already 'Disabled' here, so FTP is closed at the transport layer regardless."
  type        = bool
  default     = true
}

variable "webdeploy_publish_basic_authentication_enabled" {
  description = "Enable basic authentication for WebDeploy/SCM publishing. Defaults to true, matching the azurerm provider default. Disabling this stops FTP/S deployment from working, but does not change the FTP policy itself - ARM models the two as independent resources, so set ftp_publish_basic_authentication_enabled = false too."
  type        = bool
  default     = true
}

variable "storage_plugin_app_settings_enabled" {
  description = "Set the MICROSOFT_AZURE_ACCOUNT_NAME, MICROSOFT_AZURE_CONTAINER and MICROSOFT_AZURE_ACCOUNT_KEY app settings on the app and its staging slot. Defaults to true, which keeps the behaviour of every earlier release. Those names are read only by the Microsoft Azure Storage for WordPress plugin, as wp-config.php constants; the container image does not read them. Without that plugin they are inert, and false removes them - including the storage account key from the app's environment. The storage-key Key Vault secret is unaffected."
  type        = bool
  default     = true
  nullable    = false
}

variable "extra_app_settings" {
  description = "Additional app settings to merge with the default WordPress settings (e.g., WP_ENVIRONMENT_TYPE, custom plugin config)"
  type        = map(string)
  default     = {}
}

variable "extra_sticky_app_setting_names" {
  description = "Additional app setting names to mark as sticky (slot-specific, not swapped)"
  type        = list(string)
  default     = []
}

variable "sticky_connection_string_names" {
  description = "Connection string names to mark as sticky (slot-specific, not swapped)"
  type        = list(string)
  default     = []
}

variable "staging_app_settings_override" {
  description = "App settings to override in the staging slot (merged on top of production settings)"
  type        = map(string)
  default     = {}
}

variable "staging_always_on" {
  description = "Keep the staging slot always loaded (set to false to save cost)"
  type        = bool
  default     = false
}

variable "staging_slot_enabled" {
  description = "Create the staging deployment slot when the SKU supports one (S* and P*). Defaults to true, which keeps the behaviour of every earlier release. false creates no slot on any SKU, and on an existing deployment destroys the slot together with its managed identity; the staging_slot_* outputs are then null."
  type        = bool
  default     = true
  nullable    = false
}

# Scheduled custom backup of the production app, never the slot. Off by default.
#
# A custom App Service backup authorises with a container SAS only: managed identity is
# not supported for backup and restore. The caller supplies the SAS URL; the
# wordpress-site composition generates one from the site's storage account with a
# stable, rotated validity window (see its backup.tf). The URL is sensitive and this
# module never outputs it.

variable "backup_enabled" {
  description = "Schedule a custom App Service backup of the production app to backup_storage_account_url. Off by default. The staging slot is never backed up. Also sets virtual_network_backup_restore_enabled, so the backup and any restore travel over the app's VNet integration and the target account can keep denying public access. Basic, Standard and Premium SKUs support it. See the README's Backup section."
  type        = bool
  default     = false
  nullable    = false
}

variable "backup_storage_account_url" {
  description = "SAS URL of the private blob container that receives the backups, https://<account>.blob.core.windows.net/<container>?<sas>, with read, write, delete and list permissions. Required when backup_enabled is true. Sensitive, and never written to an output."
  type        = string
  default     = null
  sensitive   = true
}

variable "backup_frequency_interval" {
  description = "How often the backup runs, in backup_frequency_unit units: 1 with Day is daily, 7 with Day is weekly. With Hour it must be at least 2: App Service allows one custom backup every 2 hours at most, 12 a day."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.backup_frequency_interval >= 1 && var.backup_frequency_interval <= 1000 && floor(var.backup_frequency_interval) == var.backup_frequency_interval
    error_message = "backup_frequency_interval must be a whole number from 1 to 1000."
  }
}

variable "backup_frequency_unit" {
  description = "Unit of backup_frequency_interval: Day or Hour."
  type        = string
  default     = "Day"
  nullable    = false

  validation {
    condition     = contains(["Day", "Hour"], var.backup_frequency_unit)
    error_message = "backup_frequency_unit must be \"Day\" or \"Hour\"."
  }
}

variable "backup_retention_period_days" {
  description = "Days after which a backup is deleted, 0 to 30: App Service custom backups allow no longer retention. 0 keeps backups indefinitely."
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition     = var.backup_retention_period_days >= 0 && var.backup_retention_period_days <= 30 && floor(var.backup_retention_period_days) == var.backup_retention_period_days
    error_message = "backup_retention_period_days must be a whole number from 0 to 30 (0 keeps backups indefinitely): App Service custom backups allow no longer retention."
  }
}

variable "backup_keep_at_least_one_backup" {
  description = "Keep the most recent backup even once it is older than backup_retention_period_days."
  type        = bool
  default     = true
  nullable    = false
}

variable "backup_start_time" {
  description = "When the schedule starts, in RFC 3339 (for example 2026-11-01T02:00:00Z). null (the default) starts it when the backup is configured."
  type        = string
  default     = null

  validation {
    condition     = var.backup_start_time == null ? true : can(formatdate("YYYY", var.backup_start_time))
    error_message = "backup_start_time must be null or an RFC 3339 timestamp such as 2026-11-01T02:00:00Z."
  }
}

variable "cloudflare_ipv4_cidr_blocks" {
  description = "Cloudflare IPv4 CIDR blocks for origin IP restrictions. When null, uses the built-in fallback list. Pass data.cloudflare_ip_ranges.current[0].ipv4_cidrs for live updates."
  type        = list(string)
  default     = null
}

variable "cloudflare_ipv6_cidr_blocks" {
  description = "Cloudflare IPv6 CIDR blocks for origin IP restrictions. When null, uses the built-in fallback list. Pass data.cloudflare_ip_ranges.current[0].ipv6_cidrs for live updates."
  type        = list(string)
  default     = null
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
