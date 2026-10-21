# Database Module - Layer 2 Application
# Creates MySQL Flexible Server with VNet integration
# CRITICAL: Use D-series SKU for production (Burstable depletes CPU credits)

locals {
  # Short environment suffix for naming
  env_suffix = var.environment == "nonprod" ? "np" : "prod"

  # Resource naming following convention
  name_prefix = "${var.project_name}-${var.site_name}-${local.env_suffix}"

  # Validate D-series for production
  is_burstable  = can(regex("^B_", var.sku_name))
  is_production = var.environment == "production"
}

# Production D-series validation
# CRITICAL: Burstable SKUs deplete CPU credits under sustained WordPress load
resource "null_resource" "validate_production_sku" {
  count = var.enforce_production_sku && local.is_production && local.is_burstable ? 1 : 0

  triggers = {
    error = "ERROR: Production environment requires D-series MySQL SKU (GP_Standard_D*). Burstable SKUs (${var.sku_name}) deplete CPU credits under sustained load. Use GP_Standard_D2ds_v4 or higher."
  }

  lifecycle {
    precondition {
      condition     = !(local.is_production && local.is_burstable)
      error_message = "Production environment requires D-series MySQL SKU. Burstable SKUs deplete CPU credits."
    }
  }
}

# MySQL Flexible Server
resource "azurerm_mysql_flexible_server" "main" {
  #checkov:skip=CKV_AZURE_53:public network access is off through VNet integration (delegated_subnet_id with private_dns_zone_id); the check reads public_network_access_enabled, which AzureRM 5 replaced with public_network_access
  name                   = "mysql-${local.name_prefix}"
  resource_group_name    = var.resource_group_name
  location               = var.location
  administrator_login    = var.admin_username
  administrator_password = var.admin_password

  # SKU configuration
  sku_name = var.sku_name

  # Storage configuration
  storage {
    size_gb           = var.storage_size_gb
    iops              = var.storage_iops
    auto_grow_enabled = var.storage_auto_grow_enabled
  }

  # Backup configuration
  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = var.geo_redundant_backup

  # High Availability (optional per-site)
  dynamic "high_availability" {
    for_each = var.high_availability_mode != "Disabled" ? [1] : []
    content {
      mode = var.high_availability_mode
    }
  }

  # VNet integration via delegated subnet
  delegated_subnet_id = var.db_subnet_id
  private_dns_zone_id = var.private_dns_zone_id

  # Microsoft Entra ID authentication, stage 1 of the passwordless access path. The server
  # needs a user-assigned identity before it can validate Entra tokens. Added and removed in
  # place: the identity block is not ForceNew in azurerm 5.x. The module neither creates the
  # identity nor grants it Microsoft Graph permissions.
  dynamic "identity" {
    for_each = var.entra_admin_enabled ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = [var.entra_server_identity.id]
    }
  }

  # Security settings
  # ssl_enforcement_enabled is deprecated - use require_secure_transport parameter
  version = var.mysql_version

  tags = merge(var.tags, {
    Site = var.site_name
  })

  lifecycle {
    # Prevent accidental destruction of database
    prevent_destroy = false # Set to true in production

    # Checked on the server, which reads entra_server_identity first, so a missing input
    # fails here with this message and not with an error about a null object.
    precondition {
      condition     = !var.entra_admin_enabled || (var.entra_server_identity != null && var.entra_admin != null)
      error_message = "entra_admin_enabled is true, so entra_server_identity and entra_admin must both be set."
    }

    # Ignore changes to password (managed externally)
    ignore_changes = [
      administrator_password
    ]
  }
}

# MySQL Server Parameter: Require secure transport (TLS)
# OFF by default, as in every earlier release: traffic is already confined to the VNet
# with a delegated subnet, and the Microsoft WordPress container does not verify the
# server certificate. require_secure_transport = true sets ON, which also stops the
# server accepting a token login without TLS once the app uses a managed identity.
resource "azurerm_mysql_flexible_server_configuration" "require_secure_transport" {
  name                = "require_secure_transport"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mysql_flexible_server.main.name
  value               = var.require_secure_transport ? "ON" : "OFF"
}

# Microsoft Entra administrator, stage 1. Layout B points object_id at the app's own
# identity, so no Microsoft Graph permission is needed; Layout A uses a separate server
# identity that holds the Graph permissions. AVM check: the avm-res-dbformysql-flexibleserver
# module (0.x) carries this resource only inside the whole-server module and caps azurerm at
# ~> 4.0, so it cannot be called here; the azurerm resource is used directly.
resource "azurerm_mysql_flexible_server_active_directory_administrator" "main" {
  count = var.entra_admin_enabled ? 1 : 0

  server_id = azurerm_mysql_flexible_server.main.id
  # Passed on exactly as given: the module does not translate it. See the entra_admin input.
  identity_id = var.entra_server_identity.id
  login       = var.entra_admin.login
  object_id   = var.entra_admin.object_id
  tenant_id   = var.entra_admin.tenant_id

  depends_on = [time_sleep.entra_admin_identity]
}

# A pause between attaching the identity to the server and creating the administrator. On a
# first apply the identity can still be propagating when the administrator is created, and the
# API then fails transiently; the AVM MySQL module has active_directory_administrator_wait_seconds
# for the same reason. Exists only with the administrator, and only when the wait is above 0.
# Its one trigger is the server identity's ID: the delay runs when the sleep is created and
# again when the identity is swapped for another, and never delays a plan that changes neither.
resource "time_sleep" "entra_admin_identity" {
  count = var.entra_admin_enabled && var.entra_admin_wait_seconds > 0 ? 1 : 0

  create_duration = "${var.entra_admin_wait_seconds}s"

  triggers = {
    identity_id = try(var.entra_server_identity.id, "")
  }

  depends_on = [azurerm_mysql_flexible_server.main]
}

# The aad_auth_only parameter (stage 4) is deliberately NOT here. It lives in the composition,
# which orders it after the app update: this module is applied before module.app_service, so a
# resource here would switch password logins off before the app had its token login.

# MySQL Server Parameters: slow query log (opt-in).
# Both parameters are dynamic, so no restart. Deleting a configuration resource resets
# the parameter to its server default, so turning the opt-in off is a clean undo.
resource "azurerm_mysql_flexible_server_configuration" "slow_query_log" {
  count = var.slow_query_log_enabled ? 1 : 0

  name                = "slow_query_log"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mysql_flexible_server.main.name
  value               = "ON"
}

resource "azurerm_mysql_flexible_server_configuration" "long_query_time" {
  count = var.slow_query_log_enabled ? 1 : 0

  name                = "long_query_time"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mysql_flexible_server.main.name
  value               = tostring(var.long_query_time)
}

# WordPress Database
resource "azurerm_mysql_flexible_database" "wordpress" {
  name                = "wordpress"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mysql_flexible_server.main.name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
}

# Note: this module creates no database snapshot around a deployment slot swap or any other
# automation. Take an on-demand backup before a risky change, and restore with point-in-time
# restore. See: docs/operations/backup-and-restore.md
