# Storage Module Outputs
# These outputs are consumed by App Service module

output "account_id" {
  description = "ID of the Storage Account"
  value       = azurerm_storage_account.main.id
}

output "account_name" {
  description = "Name of the Storage Account"
  value       = azurerm_storage_account.main.name
}

output "primary_blob_endpoint" {
  description = "Primary blob endpoint URL"
  value       = azurerm_storage_account.main.primary_blob_endpoint
}

output "container_name" {
  description = "Name of the uploads container"
  value       = azurerm_storage_container.uploads.name
}

output "primary_access_key" {
  description = "Primary access key for the Storage Account"
  value       = azurerm_storage_account.main.primary_access_key
  sensitive   = true
}

output "primary_connection_string" {
  description = "Primary connection string for the Storage Account"
  value       = azurerm_storage_account.main.primary_connection_string
  sensitive   = true
}
