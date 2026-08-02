# Key Vault Module Variables
# Layer 2 Application - Secrets Management

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

variable "tenant_id" {
  description = "Azure AD tenant ID"
  type        = string
}

variable "app_service_principal_id" {
  description = "Principal ID of the App Service managed identity"
  type        = string
}

variable "secrets" {
  description = "Map of secrets to store in Key Vault"
  type        = map(string)
  sensitive   = true
  default     = {}
}

variable "soft_delete_retention_days" {
  description = "Days to retain soft-deleted secrets (7-90)"
  type        = number
  default     = 90

  validation {
    condition     = var.soft_delete_retention_days >= 7 && var.soft_delete_retention_days <= 90
    error_message = "Soft delete retention must be between 7 and 90 days."
  }
}

variable "purge_protection_enabled" {
  description = "Enable purge protection (recommended for production)"
  type        = bool
  default     = true
}

variable "public_network_access_enabled" {
  description = "Allow unrestricted public network access to the vault data plane (network_acls default_action = Allow). Defaults to false, which denies by default. IMPORTANT: a denying vault with no ip_rules and no subnet ids is unreachable by Terraform itself, so secret creation will fail with 403 - allow-list your deployment principal via network_acls_ip_rules, or set this to true."
  type        = bool
  default     = false
}

variable "network_acls_ip_rules" {
  description = "Public IPv4 addresses or CIDRs permitted to reach the vault data plane. Add the deploying principal's egress IP (e.g. the CI runner) so Terraform can manage secrets while default_action is Deny."
  type        = list(string)
  default     = []
}

variable "network_acls_virtual_network_subnet_ids" {
  description = "Subnet IDs permitted to reach the vault data plane. The subnets must carry the Microsoft.KeyVault service endpoint."
  type        = list(string)
  default     = []
}

variable "name_suffix" {
  description = "Suffix appended to Key Vault name to avoid conflicts with soft-deleted vaults. Bump this when a vault with purge protection is soft-deleted and the name must be reused."
  type        = string
  default     = "9"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
