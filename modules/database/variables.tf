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

variable "storage_auto_grow_enabled" {
  description = "Enable auto-grow for MySQL storage when capacity is low"
  type        = bool
  default     = true
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

# WARNING: azurerm marks geo_redundant_backup_enabled as ForceNew - geo-redundancy can
# only be chosen when the server is created. Changing this on an existing server produces
# a plan that DESTROYS AND RECREATES it, losing all data (prevent_destroy is false below).
# Decide at creation time; to change it later, back up and restore deliberately.
variable "geo_redundant_backup" {
  description = "Enable geo-redundant backup (recommended for production). FORCES REPLACEMENT: azurerm can only set this at creation, so changing it on an existing server destroys and recreates it. Choose at creation time."
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

# Named mysql_version because "version" is reserved for module input variables.
variable "mysql_version" {
  description = "MySQL Flexible Server version. The default, 8.0.21, is the version every existing server was created with, so leaving it unset changes nothing. Changing it on an existing server is a major-version upgrade that cannot be undone: rehearse it first on a restored copy, following Microsoft's major version upgrade guide (https://learn.microsoft.com/azure/mysql/flexible-server/how-to-upgrade), then take an on-demand backup immediately before the production upgrade. Whether azurerm performs the change in place or forces replacement depends on the provider version, so read the provider documentation for your version and dry-run first. This input only enables the change."
  type        = string
  default     = "8.0.21"
  nullable    = false

  validation {
    condition     = contains(["8.0.21", "8.4"], var.mysql_version)
    error_message = "mysql_version must be \"8.0.21\" or \"8.4\". 5.7 is excluded: moving to it would be a downgrade."
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

# Slow query log. Opt-in: the MySqlSlowLogs diagnostic category carries rows only once
# the slow_query_log server parameter is ON. Audit logging is deliberately not offered.
variable "slow_query_log_enabled" {
  description = "Set the slow_query_log server parameter to ON, and long_query_time with it, so the MySqlSlowLogs diagnostic category carries rows. Off (the default) leaves both parameters unmanaged. Turning it off again deletes the two configuration resources, which resets both parameters to their server defaults (OFF and 10 seconds)."
  type        = bool
  default     = false
  nullable    = false
}

variable "long_query_time" {
  description = "Seconds a statement must run to be logged as slow (the long_query_time server parameter). Applied only when slow_query_log_enabled is true. Defaults to 2, a WordPress-oriented value; the server's own default is 10. Fractions are allowed; 0 logs every statement. A change applies to new connections only."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.long_query_time >= 0 && var.long_query_time <= 31536000
    error_message = "long_query_time must be between 0 and 31536000 seconds."
  }
}

# Passwordless access with a managed identity. Everything below is off by default and the
# two flags are flat top-level bools, like the other security-relevant switches. The module
# creates no identity and grants no Microsoft Graph permission: the caller owns both.
variable "entra_admin_enabled" {
  description = "Attach entra_server_identity to the server and set entra_admin as its Microsoft Entra administrator. Off by default. Both are in-place changes in azurerm 5.x; neither replaces the server. Requires entra_server_identity and entra_admin."
  type        = bool
  default     = false
  nullable    = false
}

variable "entra_server_identity" {
  description = "The user-assigned identity the server uses to validate Microsoft Entra tokens: its resource ID, client ID and principal ID. Used only while entra_admin_enabled is true, and only its id is read. With Layout A it needs the Microsoft Graph permissions User.Read.All, GroupMember.Read.All and Application.Read.All, granted by the caller; with Layout B (the administrator is the app's own identity) it needs none."
  type = object({
    id           = string
    client_id    = string
    principal_id = string
  })
  default = null
}

variable "entra_admin" {
  description = "The server's Microsoft Entra administrator: login (the MySQL user name, at most 32 characters), object_id and tenant_id. Used only while entra_admin_enabled is true. object_id is passed to the provider exactly as given; the module does not translate it. The azurerm documentation names the identity's client ID for a managed identity, while the design rehearsal on a real server set the administrator by the identity's principal (object) ID and it worked, so confirm on the first apply on a non-production server and use the value that proves out for you."
  type = object({
    login     = string
    object_id = string
    tenant_id = string
  })
  default = null

  validation {
    condition     = var.entra_admin == null ? true : length(var.entra_admin.login) >= 1 && length(var.entra_admin.login) <= 32
    error_message = "entra_admin.login is a MySQL user name and must be 1 to 32 characters."
  }
}

variable "entra_admin_wait_seconds" {
  description = "Seconds to wait after the server and its identity exist and before the Entra administrator is created, because a freshly attached identity can still be propagating and the API then fails transiently. Used only while entra_admin_enabled is true; 0 skips the wait. The pause happens once, when it is first created."
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition     = var.entra_admin_wait_seconds >= 0 && var.entra_admin_wait_seconds <= 300 && floor(var.entra_admin_wait_seconds) == var.entra_admin_wait_seconds
    error_message = "entra_admin_wait_seconds must be a whole number from 0 to 300."
  }
}

variable "aad_auth_only_enabled" {
  description = "Set the aad_auth_only server parameter to ON, so only Microsoft Entra logins work and the password administrator can no longer connect. Off by default, which leaves the parameter unmanaged. Requires entra_admin_enabled. Turning it off again deletes the configuration resource, which resets the parameter to its server default (OFF)."
  type        = bool
  default     = false
  nullable    = false
}

variable "require_secure_transport" {
  description = "Set the require_secure_transport server parameter to ON, so the server refuses connections made without TLS, token logins included. The default, false, keeps the OFF every earlier release set. Changing it applies at once and refuses any client that does not use TLS."
  type        = bool
  default     = false
  nullable    = false
}
