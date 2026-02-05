# Key Vault Module - Layer 2 Application
# Creates Key Vault for secrets management with managed identity access

data "azurerm_client_config" "current" {}

locals {
  # Short environment suffix for naming
  env_suffix = var.environment == "nonprod" ? "np" : "prod"

  # Key Vault names have 24 char limit - abbreviate
  # Pattern: kv-{site}-{env}9 (site max ~14, env = 2-4, suffix = 1)
  # The "9" suffix avoids conflicts with soft-deleted vaults from previous deployments
  # (np, np2-np8 are all soft-deleted and can't be purged due to purge protection)
  kv_name = "kv-${substr(replace(var.site_name, "-", ""), 0, 14)}-${local.env_suffix}9"
}

# Key Vault
resource "azurerm_key_vault" "main" {
  name                = local.kv_name
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id

  # SKU (standard is sufficient for secrets)
  sku_name = "standard"

  # Security settings
  enabled_for_deployment          = false
  enabled_for_disk_encryption     = false
  enabled_for_template_deployment = false
  enable_rbac_authorization       = false # Use access policies
  purge_protection_enabled        = var.purge_protection_enabled
  soft_delete_retention_days      = var.soft_delete_retention_days

  # Network rules - allow public access for CI/CD deployment
  # Can be locked down after initial deployment if needed
  network_acls {
    bypass                     = "AzureServices"
    default_action             = var.public_network_access_enabled ? "Allow" : "Deny"
    ip_rules                   = []
    virtual_network_subnet_ids = []
  }

  tags = merge(var.tags, {
    Site = var.site_name
  })

  lifecycle {
    prevent_destroy = false # Set to true in production
  }
}

# Access policy for App Service managed identity
# Only create when a valid principal_id is provided (not empty or all-zeros)
resource "azurerm_key_vault_access_policy" "app_service" {
  count = var.app_service_principal_id != "" && var.app_service_principal_id != "00000000-0000-0000-0000-000000000000" ? 1 : 0

  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = var.tenant_id
  object_id    = var.app_service_principal_id

  # Secrets only - App Service needs to read DB password, storage key, etc.
  secret_permissions = [
    "Get",
    "List"
  ]
}

# Access policy for Terraform (current deployment principal)
resource "azurerm_key_vault_access_policy" "terraform" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  # Full secret management for deployment
  secret_permissions = [
    "Get",
    "List",
    "Set",
    "Delete",
    "Purge",
    "Recover"
  ]
}

# Store secrets
# NOTE: Using nonsensitive() for keys only - values remain sensitive
resource "azurerm_key_vault_secret" "secrets" {
  for_each = nonsensitive(toset(keys(var.secrets)))

  name         = each.value
  value        = var.secrets[each.value]
  key_vault_id = azurerm_key_vault.main.id

  # Content type helps identify secret purpose (CKV_AZURE_114)
  content_type = "text/plain"

  # Ensure access policies are created first
  depends_on = [
    azurerm_key_vault_access_policy.terraform
  ]

  tags = merge(var.tags, {
    Site = var.site_name
  })
}
