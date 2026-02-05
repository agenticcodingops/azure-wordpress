# Monitoring Module Variables
# Layer 2 Application - Application Insights, Log Analytics, and Alerts

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

# Log Analytics Workspace (shared per environment)
variable "log_analytics_workspace_id" {
  description = "ID of existing Log Analytics Workspace. If null, a new workspace is created."
  type        = string
  default     = null
}

variable "retention_days" {
  description = "Log retention in days (30 nonprod, 90 production recommended)"
  type        = number
  default     = 30

  validation {
    condition     = var.retention_days >= 30 && var.retention_days <= 730
    error_message = "Retention must be between 30 and 730 days."
  }
}

# Resources to monitor
variable "app_service_id" {
  description = "ID of the App Service to monitor"
  type        = string
}

variable "mysql_server_id" {
  description = "ID of the MySQL server to monitor"
  type        = string
  default     = ""
}

variable "front_door_profile_id" {
  description = "ID of the Front Door profile to monitor"
  type        = string
  default     = ""
}

# Alert configuration
variable "alert_recipients" {
  description = "Email addresses for alert notifications"
  type        = list(string)
  default     = []
}

variable "alert_rules" {
  description = "Alert threshold configuration"
  type = object({
    http_5xx_threshold   = optional(number, 10)
    high_cpu_threshold   = optional(number, 80)
    db_failure_threshold = optional(number, 5)
    alert_window_minutes = optional(number, 5)
  })
  default = {}
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
