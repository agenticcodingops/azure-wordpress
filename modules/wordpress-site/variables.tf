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

# Site configuration
variable "custom_domain" {
  description = "Custom domain for the WordPress site"
  type        = string
}

variable "wordpress_version" {
  description = "WordPress Docker image tag (PHP version)"
  type        = string
  default     = "8.4"
}

# Database configuration
# NOTE: sku_name, backup_retention_days and geo_redundant_backup intentionally carry
# NO default. Their default is selected by environment in main.tf's db_config local;
# giving them an optional() default here would mean null never reaches that coalesce
# and the environment-aware branch could never run.
variable "database" {
  description = "Database configuration. sku_name, backup_retention_days and geo_redundant_backup default by environment when unset - see the Environment-aware Defaults section of the README. NOTE: geo_redundant_backup forces replacement of the MySQL server, so set it explicitly on an existing deployment before upgrading."
  type = object({
    sku_name                  = optional(string)
    storage_size_gb           = optional(number, 100)
    storage_iops              = optional(number, 700)
    backup_retention_days     = optional(number)
    geo_redundant_backup      = optional(bool)
    high_availability_mode    = optional(string, "Disabled")
    storage_auto_grow_enabled = optional(bool, true)
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
    enable_waf                     = optional(bool, false) # Default false for Free plan compatibility
    enable_page_rules              = optional(bool, true)  # Free plan: 3 rules (wp-admin bypass, wp-login bypass, wp-content cache)
    enable_cache_rules             = optional(bool, false) # Requires paid plan
    enable_zone_setting_overrides  = optional(bool, false) # Some settings can't be modified on Free plan
    enable_wordpress_optimizations = optional(bool, true)
  })
  default = {}
}

# Monitoring configuration
variable "monitoring" {
  description = "Monitoring configuration"
  type = object({
    log_analytics_workspace_id = optional(string, null)
    retention_days             = optional(number)
    alerts = optional(object({
      http_5xx_threshold   = optional(number, 10)
      high_cpu_threshold   = optional(number, 80)
      db_failure_threshold = optional(number, 5)
      alert_window_minutes = optional(number, 5)
    }), {})
  })
  default = {}
}

variable "alert_recipients" {
  description = "Email addresses for alert notifications"
  type        = list(string)
  default     = []
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

# App Service Plan density validation
variable "plan_density_limit" {
  description = "Maximum sites per App Service Plan (recommended 8-10 for P1v3)"
  type        = number
  default     = 10

  validation {
    condition     = var.plan_density_limit >= 1 && var.plan_density_limit <= 20
    error_message = "Plan density limit must be between 1 and 20."
  }
}
