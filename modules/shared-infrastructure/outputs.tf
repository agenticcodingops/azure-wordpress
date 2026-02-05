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
  description = "SKU of the shared App Service Plan"
  value       = azurerm_service_plan.shared.sku_name
}
