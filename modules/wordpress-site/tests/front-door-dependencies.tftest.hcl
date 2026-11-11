# Offline graph checks: Terraform 1.9.8, no credentials and no apply.
# Run with: terraform -chdir=modules/wordpress-site test (Terraform 1.7+ for mock_provider).
# Do not override either module: the real profile -> app -> origin graph must plan.
mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000001"
      object_id       = "00000000-0000-0000-0000-000000000002"
      subscription_id = "00000000-0000-0000-0000-000000000003"
    }
  }
}

mock_provider "cloudflare" {}
mock_provider "null" {}
mock_provider "random" {}
mock_provider "time" {}

variables {
  project_name  = "origincheck"
  site_name     = "origincheck"
  environment   = "nonprod"
  location      = "eastus"
  tenant_id     = "00000000-0000-0000-0000-000000000001"
  custom_domain = "origincheck.example.com"
  cdn_provider  = "azure_front_door"
  app_service = {
    sku_name = "S1"
  }
}

run "front_door_standard_graph" {
  command = plan

  assert {
    condition     = length(module.front_door) == 1 && module.app_service.staging_slot_enabled
    error_message = "The Front Door profile, app, and enabled Standard slot must plan together."
  }
}

run "front_door_basic_graph" {
  command = plan

  variables {
    app_service = {
      sku_name = "B1"
    }
  }

  assert {
    condition     = length(module.front_door) == 1 && !module.app_service.staging_slot_enabled
    error_message = "The Front Door profile and Basic app must plan without a slot."
  }
}

run "front_door_shared_standard_graph" {
  command = plan

  variables {
    app_service = {
      sku_name        = "S1"
      use_shared_plan = true
      plan_id         = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg-shared/providers/Microsoft.Web/serverFarms/asp-shared"
    }
    shared_plan_sku            = "S1"
    shared_resource_group_name = "rg-shared"
  }

  assert {
    condition     = length(module.front_door) == 1 && module.app_service.staging_slot_enabled
    error_message = "The profile, app, and slot must also plan with a shared Standard plan."
  }
}

run "direct_graph_without_profile" {
  command = plan

  variables {
    cdn_provider = "direct"
  }

  assert {
    condition     = length(module.front_door) == 0 && module.app_service.staging_slot_enabled
    error_message = "Direct mode must still plan the app and slot without a Front Door profile."
  }
}
