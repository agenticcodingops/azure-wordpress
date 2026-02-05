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
  name                   = "mysql-${local.name_prefix}"
  resource_group_name    = var.resource_group_name
  location               = var.location
  administrator_login    = var.admin_username
  administrator_password = var.admin_password

  # SKU configuration
  sku_name = var.sku_name

  # Storage configuration
  storage {
    size_gb = var.storage_size_gb
    iops    = var.storage_iops
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

  # Security settings
  # ssl_enforcement_enabled is deprecated - use require_secure_transport parameter
  version = "8.0.21"

  tags = merge(var.tags, {
    Site = var.site_name
  })

  lifecycle {
    # Prevent accidental destruction of database
    prevent_destroy = false # Set to true in production

    # Ignore changes to password (managed externally)
    ignore_changes = [
      administrator_password
    ]
  }
}

# MySQL Server Parameter: Require secure transport (TLS)
# NOTE: Set to OFF because traffic is already encrypted at the network layer
# when using VNet integration with delegated subnet. The Microsoft WordPress
# container doesn't configure TLS for MySQL connections by default.
resource "azurerm_mysql_flexible_server_configuration" "require_secure_transport" {
  name                = "require_secure_transport"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mysql_flexible_server.main.name
  value               = "OFF"
}

# WordPress Database
resource "azurerm_mysql_flexible_database" "wordpress" {
  name                = "wordpress"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mysql_flexible_server.main.name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
}

# Note: Database snapshot before WordPress update (deployment slot swap)
# is handled via Azure Automation Runbook triggered by slot swap webhook
# See: docs/runbooks/database-snapshot.md
