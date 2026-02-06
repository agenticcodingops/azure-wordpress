# Shared Infrastructure Module Outputs

output "resource_group_name" {
  description = "Name of the shared resource group"
  value       = azurerm_resource_group.shared.name
}

output "resource_group_id" {
  description = "ID of the shared resource group"
  value       = azurerm_resource_group.shared.id
}

output "app_service_plan_id" {
  description = "ID of the shared App Service Plan (pass to wordpress-site composition)"
  value       = azurerm_service_plan.shared.id
}

output "app_service_plan_name" {
  description = "Name of the shared App Service Plan"
  value       = azurerm_service_plan.shared.name
}

output "app_service_plan_sku" {
  description = "SKU of the shared App Service Plan (uses input variable for plan-time determinism)"
  # IMPORTANT: Return the input variable, not the resource attribute
  # azurerm_service_plan.shared.sku_name is unknown at plan time during initial creation,
  # which causes "count depends on unknown value" errors in downstream modules
  # that use this value to determine feature availability (e.g., slot support)
  value = var.app_service_sku
}
