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
variable "database" {
  description = "Database configuration"
  type = object({
    sku_name               = optional(string, "GP_Standard_D2ds_v4")
    storage_size_gb        = optional(number, 100)
    storage_iops           = optional(number, 700)
    backup_retention_days  = optional(number, 7)
    geo_redundant_backup   = optional(bool, false)
    high_availability_mode = optional(string, "Disabled")
  })
  default = {}
}

# App Service configuration
variable "app_service" {
  description = "App Service configuration"
  type = object({
    plan_id           = optional(string, null)
    use_shared_plan   = optional(bool, false)
    sku_name          = optional(string, "P1v3")
    always_on         = optional(bool, true)
    health_check_path = optional(string, "/")
    worker_count      = optional(number, 1)
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
    waf_mode              = optional(string, "Prevention")
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
    enable_page_rules              = optional(bool, false) # Default false for Free plan compatibility (3 rule limit)
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
    retention_days             = optional(number, 30)
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
