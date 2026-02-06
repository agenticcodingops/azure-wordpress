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
  source = "github.com/agenticcodingops/azure-wordpress//modules/wordpress-site"

  project_name  = var.project_name
  site_name     = var.site_name
  environment   = var.environment
  location      = var.location
  tenant_id     = data.azurerm_client_config.current.tenant_id
  custom_domain = var.custom_domain

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

  # App Service configuration (creates dedicated plan)
  app_service = {
    sku_name          = "B1"
    always_on         = false # B1 doesn't support always_on
    health_check_path = "/wp-includes/images/blank.gif"
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
