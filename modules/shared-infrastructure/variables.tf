# Shared Infrastructure Module Variables

variable "project_name" {
  description = "Project name used in resource naming (lowercase, 2-24 chars)"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,22}[a-z0-9]$", var.project_name))
    error_message = "Project name must be 2-24 lowercase alphanumeric characters with optional hyphens."
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

variable "app_service_sku" {
  description = "App Service Plan SKU (B1 for dev/test, P1v3 for production scale)"
  type        = string
  default     = "B1"

  validation {
    condition     = can(regex("^(B|S|P)[0-9]v?[0-9]?$", var.app_service_sku))
    error_message = "SKU must be a valid App Service Plan SKU (e.g., B1, S1, P1v3)."
  }
}

variable "worker_count" {
  description = "Number of workers (instances) for the shared plan"
  type        = number
  default     = 1

  validation {
    condition     = var.worker_count >= 1 && var.worker_count <= 30
    error_message = "Worker count must be between 1 and 30."
  }
}

variable "enable_autoscale" {
  description = "Enable auto-scaling for the shared App Service Plan"
  type        = bool
  default     = false
}

variable "autoscale_min_workers" {
  description = "Minimum number of workers for auto-scaling"
  type        = number
  default     = 1

  validation {
    condition     = var.autoscale_min_workers >= 1
    error_message = "Minimum workers must be at least 1."
  }
}

variable "autoscale_max_workers" {
  description = "Maximum number of workers for auto-scaling"
  type        = number
  default     = 5

  validation {
    condition     = var.autoscale_max_workers >= 1 && var.autoscale_max_workers <= 30
    error_message = "Maximum workers must be between 1 and 30."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
