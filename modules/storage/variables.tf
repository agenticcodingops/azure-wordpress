# Storage Module Variables
# Layer 2 Application - Blob Storage for Media Uploads

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

# Network rules for the storage account data plane (AZU-0012 / CKV_AZURE_36)
#
# IMPORTANT - read before setting this to Deny.
# The WordPress Blob Storage plugin rewrites media URLs to the account's own
# endpoint (https://<account>.blob.core.windows.net/...), so visitors' browsers
# fetch media DIRECTLY from Azure, not through the CDN. Denying by default
# therefore breaks media for end users unless one of these is true:
#
#   - the blob endpoint is fronted by a CDN custom domain (CNAME) so origin
#     pulls come from the CDN's published egress ranges, which you allow-list
#     via network_rules_ip_rules; or
#   - you allow-list whatever else needs data-plane access.
#
# Azure Storage IP rules accept IPv4 only - IPv6 CIDRs are rejected - so a
# CDN's IPv6 egress ranges cannot be expressed here.
variable "network_rules_default_action" {
  description = "Default action for storage account network rules. 'Deny' is secure-by-default but blocks direct browser access to media; see the module README before changing."
  type        = string
  default     = "Deny"

  validation {
    condition     = contains(["Allow", "Deny"], var.network_rules_default_action)
    error_message = "Network rules default action must be 'Allow' or 'Deny'."
  }
}

variable "network_rules_bypass" {
  description = "Traffic permitted to bypass the network rules. Valid values: AzureServices, Logging, Metrics, None."
  type        = set(string)
  default     = ["AzureServices"]
}

variable "network_rules_ip_rules" {
  description = "Public IPv4 addresses or CIDRs permitted to reach the storage data plane. Azure Storage does not accept IPv6 CIDRs, nor /31 and /32 prefixes (use a bare IP instead)."
  type        = list(string)
  default     = []
}

variable "network_rules_virtual_network_subnet_ids" {
  description = "Subnet IDs permitted to reach the storage data plane. The subnets must carry the Microsoft.Storage service endpoint."
  type        = list(string)
  default     = []
}

variable "account_tier" {
  description = "Storage account tier (Standard or Premium)"
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Standard", "Premium"], var.account_tier)
    error_message = "Account tier must be 'Standard' or 'Premium'."
  }
}

variable "account_replication_type" {
  description = "Storage account replication type"
  type        = string
  default     = "LRS"

  validation {
    condition     = contains(["LRS", "GRS", "RAGRS", "ZRS", "GZRS", "RAGZRS"], var.account_replication_type)
    error_message = "Invalid replication type."
  }
}

variable "container_name" {
  description = "Name of the blob container for WordPress uploads"
  type        = string
  default     = "wp-uploads"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.container_name))
    error_message = "Container name must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "additional_containers" {
  description = "Map of additional blob containers to create (e.g., wp-backups for UpdraftPlus)"
  type = map(object({
    access_type = optional(string, "private")
  }))
  default = {}

  validation {
    condition = alltrue([
      for name, config in var.additional_containers :
      contains(["private", "blob", "container"], config.access_type)
    ])
    error_message = "Container access_type must be 'private', 'blob', or 'container'."
  }
}

variable "versioning_enabled" {
  description = "Enable blob versioning for point-in-time recovery"
  type        = bool
  default     = true
}

variable "blob_delete_retention_days" {
  description = "Number of days to retain soft-deleted blobs (1-365)"
  type        = number
  default     = 30

  validation {
    condition     = var.blob_delete_retention_days >= 1 && var.blob_delete_retention_days <= 365
    error_message = "Blob delete retention must be between 1 and 365 days."
  }
}

variable "container_delete_retention_days" {
  description = "Number of days to retain soft-deleted containers (1-365)"
  type        = number
  default     = 30

  validation {
    condition     = var.container_delete_retention_days >= 1 && var.container_delete_retention_days <= 365
    error_message = "Container delete retention must be between 1 and 365 days."
  }
}

variable "lifecycle_policy_enabled" {
  description = "Enable lifecycle management policy for blob tiering and version cleanup"
  type        = bool
  default     = true
}

variable "lifecycle_cool_tier_days" {
  description = "Days since last access before moving base blobs to Cool tier"
  type        = number
  default     = 30

  validation {
    condition     = var.lifecycle_cool_tier_days >= 1
    error_message = "Cool tier days must be at least 1."
  }
}

variable "lifecycle_version_delete_days" {
  description = "Days since creation before deleting old blob versions"
  type        = number
  default     = 90

  validation {
    condition     = var.lifecycle_version_delete_days >= 1
    error_message = "Version delete days must be at least 1."
  }
}

variable "lifecycle_snapshot_delete_days" {
  description = "Days since creation before deleting old snapshots"
  type        = number
  default     = 90

  validation {
    condition     = var.lifecycle_snapshot_delete_days >= 1
    error_message = "Snapshot delete days must be at least 1."
  }
}

variable "lifecycle_prefix_match" {
  description = "List of blob prefixes to scope the lifecycle management policy"
  type        = list(string)
  default     = ["uploads/"]
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
