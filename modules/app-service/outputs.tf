# App Service Module Outputs
# These outputs are consumed by Front Door and monitoring modules

output "id" {
  description = "ID of the Linux Web App"
  value       = azurerm_linux_web_app.main.id
}

output "name" {
  description = "Name of the Linux Web App"
  value       = azurerm_linux_web_app.main.name
}

output "default_hostname" {
  description = "Default hostname of the Web App"
  value       = azurerm_linux_web_app.main.default_hostname
}

output "principal_id" {
  description = "Principal ID of the Web App managed identity"
  value       = azurerm_linux_web_app.main.identity[0].principal_id
}

output "tenant_id" {
  description = "Tenant ID of the Web App managed identity"
  value       = azurerm_linux_web_app.main.identity[0].tenant_id
}

output "plan_id" {
  description = "ID of the App Service Plan (created or existing)"
  value       = local.plan_id
}

output "staging_slot_id" {
  description = "ID of the staging deployment slot (null if SKU doesn't support slots)"
  value       = length(azurerm_linux_web_app_slot.staging) > 0 ? azurerm_linux_web_app_slot.staging[0].id : null
}

output "staging_slot_hostname" {
  description = "Hostname of the staging deployment slot (null if SKU doesn't support slots)"
  value       = length(azurerm_linux_web_app_slot.staging) > 0 ? azurerm_linux_web_app_slot.staging[0].default_hostname : null
}

output "custom_domain_verification_id" {
  description = "Custom domain verification ID for DNS TXT record (asuid.<subdomain>)"
  value       = azurerm_linux_web_app.main.custom_domain_verification_id
}
