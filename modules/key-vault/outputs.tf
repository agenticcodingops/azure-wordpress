# Key Vault Module Outputs
# These outputs are consumed by App Service module

output "id" {
  description = "ID of the Key Vault"
  value       = azurerm_key_vault.main.id
}

output "name" {
  description = "Name of the Key Vault"
  value       = azurerm_key_vault.main.name
}

output "uri" {
  description = "URI of the Key Vault"
  value       = azurerm_key_vault.main.vault_uri
}

output "secret_uris" {
  description = "Map of secret names to their versioned URIs"
  value       = { for secret_name, secret in azurerm_key_vault_secret.secrets : secret_name => secret.id }
}

output "secret_versionless_uris" {
  description = "Map of secret names to their versionless URIs (for App Service Key Vault references)"
  value       = { for secret_name, secret in azurerm_key_vault_secret.secrets : secret_name => secret.versionless_id }
}
