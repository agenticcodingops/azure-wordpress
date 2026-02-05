# Networking Module Outputs
# These outputs are consumed by Layer 2 Application modules

output "vnet_id" {
  description = "ID of the Virtual Network"
  value       = azurerm_virtual_network.main.id
}

output "vnet_name" {
  description = "Name of the Virtual Network"
  value       = azurerm_virtual_network.main.name
}

output "app_subnet_id" {
  description = "ID of the App Service integration subnet"
  value       = azurerm_subnet.app.id
}

output "app_subnet_name" {
  description = "Name of the App Service integration subnet"
  value       = azurerm_subnet.app.name
}

output "db_subnet_id" {
  description = "ID of the database (MySQL) subnet"
  value       = azurerm_subnet.db.id
}

output "db_subnet_name" {
  description = "Name of the database subnet"
  value       = azurerm_subnet.db.name
}

output "private_endpoint_subnet_id" {
  description = "ID of the private endpoint subnet"
  value       = azurerm_subnet.private_endpoints.id
}

output "private_endpoint_subnet_name" {
  description = "Name of the private endpoint subnet"
  value       = azurerm_subnet.private_endpoints.name
}
