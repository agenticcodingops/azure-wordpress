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
  description = "Path for health check endpoint"
  type        = string
  default     = "/"
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

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
