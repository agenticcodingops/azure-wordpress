# Storage Module - Layer 2 Application
# Creates Storage Account for WordPress media uploads
# NOTE: NO Azure Files mount - media offloaded via WordPress plugin

locals {
  # Short environment suffix for naming
  env_suffix = var.environment == "nonprod" ? "np" : "prod"

  # Storage account names: 3-24 chars, lowercase alphanumeric only
  # Pattern: st{project}{site}{env} (heavily abbreviated)
  storage_name = "sttr${substr(replace(var.site_name, "-", ""), 0, 12)}${local.env_suffix}"
}

# Storage Account for WordPress media uploads
resource "azurerm_storage_account" "main" {
  name                = local.storage_name
  resource_group_name = var.resource_group_name
  location            = var.location

  # Performance and redundancy
  account_tier             = var.account_tier
  account_replication_type = var.account_replication_type
  account_kind             = "StorageV2"

  # Security settings
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true # Required for WordPress plugin

  # Infrastructure encryption
  infrastructure_encryption_enabled = true

  # Data-plane network rules (AZU-0012). Denies by default; the composition module
  # allow-lists the App Service subnet and, when Cloudflare is the CDN, Cloudflare's
  # published IPv4 egress ranges. Container management still works either way -
  # azurerm_storage_container uses the ARM control plane, which these rules do not gate.
  network_rules {
    default_action             = var.network_rules_default_action
    bypass                     = var.network_rules_bypass
    ip_rules                   = var.network_rules_ip_rules
    virtual_network_subnet_ids = var.network_rules_virtual_network_subnet_ids
  }

  # SAS policy for security (CKV2_AZURE_41)
  sas_policy {
    expiration_period = "7.00:00:00" # 7 days max SAS lifetime
    expiration_action = "Log"
  }

  # Blob properties
  blob_properties {
    versioning_enabled = var.versioning_enabled

    # Enable access time tracking for lifecycle management (Infracost FinOps)
    last_access_time_enabled = true

    delete_retention_policy {
      days = var.blob_delete_retention_days
    }

    container_delete_retention_policy {
      days = var.container_delete_retention_days
    }

    # CORS rules for WordPress media uploads
    cors_rule {
      allowed_headers    = ["*"]
      allowed_methods    = ["GET", "HEAD", "PUT", "OPTIONS"]
      allowed_origins    = ["*"] # Restricted by WAF
      exposed_headers    = ["*"]
      max_age_in_seconds = 3600
    }
  }

  tags = merge(var.tags, {
    Site = var.site_name
  })

  lifecycle {
    prevent_destroy = false # Set to true in production
  }
}

# Container for WordPress uploads
# Using private access - content served via WordPress or Azure Front Door with private link
# Public blob access is disabled on the storage account for security (CKV2_AZURE_47)
resource "azurerm_storage_container" "uploads" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private" # Secure access via SAS tokens or storage key
}

# Additional containers (e.g., wp-backups for UpdraftPlus)
resource "azurerm_storage_container" "additional" {
  for_each = var.additional_containers

  name                  = each.key
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = each.value.access_type
}

# Lifecycle Management Policy (Infracost FinOps requirement)
# Configurable tiering and version cleanup
resource "azurerm_storage_management_policy" "lifecycle" {
  count = var.lifecycle_policy_enabled ? 1 : 0

  storage_account_id = azurerm_storage_account.main.id

  rule {
    name    = "lifecycle-tiering-and-cleanup"
    enabled = true

    filters {
      prefix_match = var.lifecycle_prefix_match
      blob_types   = ["blockBlob"]
    }

    actions {
      # Move to cool tier if not accessed for N days
      base_blob {
        tier_to_cool_after_days_since_last_access_time_greater_than = var.lifecycle_cool_tier_days
      }

      # Delete old versions after N days
      version {
        delete_after_days_since_creation = var.lifecycle_version_delete_days
      }

      # Delete old snapshots after N days
      snapshot {
        delete_after_days_since_creation_greater_than = var.lifecycle_snapshot_delete_days
      }
    }
  }
}

# NOTE: NO storage_account block in App Service module
# Media uploads handled via Microsoft Azure Storage plugin for WordPress
# This avoids the 2-3 second latency from Azure Files mounts
