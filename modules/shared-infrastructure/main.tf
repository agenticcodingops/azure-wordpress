# Shared Infrastructure Module
# Creates shared resources per environment (subscription):
# - Shared Resource Group
# - Shared App Service Plan (can host 8-10 WordPress sites per P1v3)
#
# COST OPTIMIZATION: Consolidates from 1 plan per site to 1 plan per subscription
# Savings: ~50% reduction in App Service Plan costs
#
# Usage:
#   module "shared_infrastructure" {
#     source = "github.com/agenticcodingops/terraform-azure-wordpress//modules/shared-infrastructure?ref=v1.0.0"
#
#     project_name       = "myproject"
#     environment        = "nonprod"
#     location           = "West US 2"
#     app_service_sku    = "B1"
#     tags               = local.common_tags
#   }

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0.0"
    }
  }
}

locals {
  # Short environment suffix for naming
  env_suffix = var.environment == "nonprod" ? "np" : "prod"

  # Resource naming following project convention
  name_prefix = "${var.project_name}-shared-${local.env_suffix}"
}

# Shared Resource Group
# Houses shared infrastructure resources (App Service Plan, future: Log Analytics)
resource "azurerm_resource_group" "shared" {
  name     = "rg-${local.name_prefix}"
  location = var.location

  tags = merge(var.tags, {
    Service = "SharedInfrastructure"
  })
}

# Shared App Service Plan
# Hosts multiple WordPress sites (8-10 recommended for P1v3)
# CRITICAL: Linux OS type required for WordPress containers
resource "azurerm_service_plan" "shared" {
  name                = "asp-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.shared.name
  location            = var.location
  os_type             = "Linux"
  sku_name            = var.app_service_sku
  worker_count        = var.worker_count

  tags = merge(var.tags, {
    Service = "SharedInfrastructure"
  })
}

# Auto-scale settings for shared plan
# Monitors combined load from all sites on the plan
resource "azurerm_monitor_autoscale_setting" "shared" {
  count = var.enable_autoscale ? 1 : 0

  name                = "autoscale-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.shared.name
  location            = var.location
  target_resource_id  = azurerm_service_plan.shared.id

  profile {
    name = "default"

    capacity {
      default = var.worker_count
      minimum = var.autoscale_min_workers
      maximum = var.autoscale_max_workers
    }

    # Scale out on high CPU
    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.shared.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 70
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT10M"
      }
    }

    # Scale out on high memory
    rule {
      metric_trigger {
        metric_name        = "MemoryPercentage"
        metric_resource_id = azurerm_service_plan.shared.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 80
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT10M"
      }
    }

    # Scale in when metrics low
    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.shared.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT15M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 50
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT15M"
      }
    }
  }

  tags = merge(var.tags, {
    Service = "SharedInfrastructure"
  })
}
