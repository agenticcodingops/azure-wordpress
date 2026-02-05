# Front Door Module Variables
# Layer 2 Application - Azure Front Door CDN + WAF

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

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "sku_name" {
  description = "Front Door SKU (Premium_AzureFrontDoor required for WAF)"
  type        = string
  default     = "Premium_AzureFrontDoor"

  validation {
    condition     = contains(["Standard_AzureFrontDoor", "Premium_AzureFrontDoor"], var.sku_name)
    error_message = "SKU must be 'Standard_AzureFrontDoor' or 'Premium_AzureFrontDoor'."
  }
}

variable "waf_mode" {
  description = "WAF mode: Detection (log only) or Prevention (block)"
  type        = string
  default     = "Prevention"

  validation {
    condition     = contains(["Detection", "Prevention"], var.waf_mode)
    error_message = "WAF mode must be 'Detection' or 'Prevention'."
  }
}

variable "origin_hostname" {
  description = "Origin hostname (App Service default hostname)"
  type        = string
}

variable "custom_domain" {
  description = "Custom domain for the Front Door endpoint"
  type        = string
}

variable "cache_uploads_minutes" {
  description = "Cache TTL for wp-content/uploads in minutes"
  type        = number
  default     = 180

  validation {
    condition     = var.cache_uploads_minutes >= 0 && var.cache_uploads_minutes <= 525600
    error_message = "Cache TTL must be between 0 and 525600 minutes (1 year)."
  }
}

variable "cache_static_minutes" {
  description = "Cache TTL for static assets in minutes"
  type        = number
  default     = 180

  validation {
    condition     = var.cache_static_minutes >= 0 && var.cache_static_minutes <= 525600
    error_message = "Cache TTL must be between 0 and 525600 minutes (1 year)."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
