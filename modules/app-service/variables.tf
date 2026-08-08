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
  description = "Tag for the WordPress Docker image"
  type        = string
  default     = "8.4"
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
  description = "Enable basic authentication for WebDeploy/SCM publishing. Defaults to true, matching the azurerm provider default. Azure requires SCM basic auth for FTP basic auth, so setting this false disables FTP basic auth as well."
  type        = bool
  default     = true
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
