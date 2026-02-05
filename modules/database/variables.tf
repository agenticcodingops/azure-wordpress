# Database Module Variables
# Layer 2 Application - MySQL Flexible Server with Private Endpoint

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

variable "db_subnet_id" {
  description = "ID of the database subnet (from networking module)"
  type        = string
}

variable "private_dns_zone_id" {
  description = "ID of the MySQL private DNS zone (from dns-zones module)"
  type        = string
}

variable "sku_name" {
  description = "MySQL SKU name. Use GP_Standard_D2ds_v4 or higher for production (D-series REQUIRED)."
  type        = string
  default     = "GP_Standard_D2ds_v4"

  validation {
    condition     = can(regex("^(B_Standard_B|GP_Standard_D|MO_Standard_E)", var.sku_name))
    error_message = "SKU must be Burstable (B_), General Purpose (GP_), or Memory Optimized (MO_)."
  }
}

variable "storage_size_gb" {
  description = "Storage size in GB (20-16384)"
  type        = number
  default     = 100

  validation {
    condition     = var.storage_size_gb >= 20 && var.storage_size_gb <= 16384
    error_message = "Storage size must be between 20 and 16384 GB."
  }
}

variable "storage_iops" {
  description = "Storage IOPS (360-20000)"
  type        = number
  default     = 700

  validation {
    condition     = var.storage_iops >= 360 && var.storage_iops <= 20000
    error_message = "Storage IOPS must be between 360 and 20000."
  }
}

variable "backup_retention_days" {
  description = "Backup retention in days (1-35)"
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 35
    error_message = "Backup retention must be between 1 and 35 days."
  }
}

variable "geo_redundant_backup" {
  description = "Enable geo-redundant backup (recommended for production)"
  type        = bool
  default     = false
}

variable "high_availability_mode" {
  description = "High availability mode: Disabled, SameZone, or ZoneRedundant"
  type        = string
  default     = "Disabled"

  validation {
    condition     = contains(["Disabled", "SameZone", "ZoneRedundant"], var.high_availability_mode)
    error_message = "High availability mode must be 'Disabled', 'SameZone', or 'ZoneRedundant'."
  }
}

variable "admin_username" {
  description = "MySQL admin username"
  type        = string
  default     = "wpadmin"

  validation {
    condition     = !contains(["admin", "administrator", "root", "sa", "guest"], lower(var.admin_username))
    error_message = "Admin username cannot be a reserved name."
  }
}

variable "admin_password" {
  description = "MySQL admin password (store in Key Vault)"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.admin_password) >= 8
    error_message = "Admin password must be at least 8 characters."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# Production D-series validation
# CRITICAL: Burstable SKUs deplete CPU credits under sustained load
variable "enforce_production_sku" {
  description = "Enforce D-series SKU for production (fails if Burstable in prod)"
  type        = bool
  default     = true
}
