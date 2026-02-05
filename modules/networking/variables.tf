# Networking Module Variables
# Layer 1 Foundation - VNet, Subnets, NSGs

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

variable "vnet_address_space" {
  description = "Address space for the VNet in CIDR notation"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vnet_address_space, 0))
    error_message = "VNet address space must be a valid CIDR block."
  }
}

variable "app_subnet_cidr" {
  description = "CIDR block for the App Service subnet (VNet integration)"
  type        = string
  default     = "10.0.0.0/24"

  validation {
    condition     = can(cidrhost(var.app_subnet_cidr, 0))
    error_message = "App subnet CIDR must be a valid CIDR block."
  }
}

variable "db_subnet_cidr" {
  description = "CIDR block for the database subnet (MySQL Private Endpoint)"
  type        = string
  default     = "10.0.1.0/24"

  validation {
    condition     = can(cidrhost(var.db_subnet_cidr, 0))
    error_message = "Database subnet CIDR must be a valid CIDR block."
  }
}

variable "private_endpoint_subnet_cidr" {
  description = "CIDR block for private endpoints (Storage, Key Vault)"
  type        = string
  default     = "10.0.2.0/24"

  validation {
    condition     = can(cidrhost(var.private_endpoint_subnet_cidr, 0))
    error_message = "Private endpoint subnet CIDR must be a valid CIDR block."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
