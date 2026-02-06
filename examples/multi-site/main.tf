# Multi-Site Example with Shared App Service Plan
# Deploy multiple WordPress sites sharing a single App Service Plan

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

# ============================================================================
# SHARED INFRASTRUCTURE
# One App Service Plan hosts multiple WordPress sites
# ============================================================================

module "shared" {
  # Pin to a specific version tag for stability
  source = "github.com/agenticcodingops/azure-wordpress//modules/shared-infrastructure?ref=v1.0.0"

  project_name    = var.project_name
  environment     = var.environment
  location        = var.location
  app_service_sku = var.app_service_sku

  tags = var.tags
}

# ============================================================================
# WORDPRESS SITES
# Each site uses the shared App Service Plan
# ============================================================================

module "wordpress_sites" {
  for_each = var.sites
  # Pin to a specific version tag for stability
  source   = "github.com/agenticcodingops/azure-wordpress//modules/wordpress-site?ref=v1.0.0"

  project_name  = var.project_name
  site_name     = each.key
  environment   = var.environment
  location      = var.location
  tenant_id     = data.azurerm_client_config.current.tenant_id
  custom_domain = each.value.custom_domain

  # Use shared App Service Plan
  app_service = {
    plan_id           = module.shared.app_service_plan_id
    use_shared_plan   = true
    sku_name          = var.app_service_sku
    always_on         = !startswith(var.app_service_sku, "B") # B-tier doesn't support always_on
    health_check_path = "/wp-includes/images/blank.gif"
  }
  shared_resource_group_name = module.shared.resource_group_name
  shared_plan_sku            = var.app_service_sku

  # Cloudflare CDN
  cdn_provider = "cloudflare"
  cloudflare = {
    enabled    = true
    account_id = var.cloudflare_account_id
    domain     = var.cloudflare_domain
    subdomain  = each.value.subdomain
    proxied    = true
  }

  # Database per site (required for isolation)
  database = {
    sku_name        = each.value.database_sku
    storage_size_gb = each.value.database_storage_gb
  }

  tags = var.tags
}

# ============================================================================
# OUTPUTS
# ============================================================================

output "shared_resource_group" {
  description = "Shared resource group name"
  value       = module.shared.resource_group_name
}

output "shared_app_service_plan" {
  description = "Shared App Service Plan ID"
  value       = module.shared.app_service_plan_id
}

output "sites" {
  description = "Deployed WordPress sites"
  value = {
    for site_name, site in module.wordpress_sites : site_name => {
      wordpress_url  = site.wordpress_url
      admin_url      = site.wordpress_admin_url
      resource_group = site.resource_group_name
      app_service    = site.app_service_default_hostname
    }
  }
}
