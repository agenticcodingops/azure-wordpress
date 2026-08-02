# Basic Single Site Example
# Deploy a single WordPress site with Cloudflare CDN

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = ">= 4.0.0"
    }
  }
}

# Configure providers
provider "azurerm" {
  features {}
  subscription_id = var.azure_subscription_id
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# Get current Azure configuration
data "azurerm_client_config" "current" {}

# Deploy WordPress site
module "wordpress" {
  # Pin to a specific version tag for stability
  source = "github.com/agenticcodingops/azure-wordpress//modules/wordpress-site?ref=v3.0.0"

  project_name  = var.project_name
  site_name     = var.site_name
  environment   = var.environment
  location      = var.location
  tenant_id     = data.azurerm_client_config.current.tenant_id
  custom_domain = var.custom_domain

  # ---------------------------------------------------------------------------
  # Data-plane network access. Both Key Vault and Storage DENY public access by
  # default (v2.0.0+). Leaving these unset makes a first apply fail, so they are
  # set explicitly here rather than left as an exercise.
  # ---------------------------------------------------------------------------

  # Terraform is not a trusted Azure service: its calls to create the Key Vault
  # secrets are refused unless the deploying principal can reach the vault.
  # GitHub-hosted runners have a large rotating egress range that cannot be
  # allow-listed, hence `true` here. On a self-hosted runner with a stable IP,
  # prefer the tighter option and delete this line:
  #   key_vault_network_acls_ip_rules = ["203.0.113.10"]
  key_vault_public_network_access_enabled = true

  # The WordPress Blob Storage plugin rewrites media URLs to the account's own
  # blob endpoint, so visitors fetch media straight from Azure, from arbitrary
  # IPs. With the default "Deny" every image 403s for end users. Keep "Deny" only
  # if the blob endpoint is fronted by a CDN custom domain.
  storage_network_rules_default_action = "Allow"

  # Key Vault lifecycle (v3.0.0). Unset, these default by environment:
  # production true/90, nonprod false/7. Nonprod defaults to purge protection OFF
  # so a destroyed vault's name is immediately reusable. Uncomment to keep the
  # pre-v3.0.0 behaviour on an existing nonprod deployment and avoid a vault
  # replacement -- see modules/wordpress-site/README.md.
  #   key_vault_purge_protection_enabled   = true
  #   key_vault_soft_delete_retention_days = 90

  # Use Cloudflare for CDN (cost-optimized)
  cdn_provider = "cloudflare"
  cloudflare = {
    enabled    = true
    account_id = var.cloudflare_account_id
    domain     = var.cloudflare_domain
    subdomain  = var.cloudflare_subdomain
    proxied    = true
  }

  # Database configuration
  database = {
    sku_name        = "B_Standard_B2s" # Burstable for dev/test
    storage_size_gb = 100
  }

  # Storage configuration -- backup container for UpdraftPlus
  storage = {
    additional_containers = {
      "wp-backups" = { access_type = "private" }
    }
  }

  # App Service configuration (creates dedicated plan)
  # NOTE: B1 does not support deployment slots -- use S1+ for staging
  app_service = {
    sku_name          = "B1"
    always_on         = false # B1 doesn't support always_on
    health_check_path = "/wp-includes/images/blank.gif"

    extra_app_settings             = { "WP_ENVIRONMENT_TYPE" = "production" }
    extra_sticky_app_setting_names = ["WP_ENVIRONMENT_TYPE"]
    staging_app_settings_override  = { "WP_ENVIRONMENT_TYPE" = "staging" }
  }

  tags = {
    Owner = "DevOps"
  }
}

# Outputs
output "app_service_url" {
  description = "App Service default hostname"
  value       = "https://${module.wordpress.app_service_default_hostname}"
}

output "wordpress_url" {
  description = "WordPress site URL"
  value       = module.wordpress.wordpress_url
}

output "wordpress_admin_url" {
  description = "WordPress admin URL"
  value       = module.wordpress.wordpress_admin_url
}

output "resource_group_name" {
  description = "Resource group containing site resources"
  value       = module.wordpress.resource_group_name
}
