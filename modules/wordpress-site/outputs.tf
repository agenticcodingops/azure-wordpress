# WordPress Site Composition Outputs

output "site_name" {
  description = "The site name"
  value       = var.site_name
}

output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.main.name
}

output "resource_group_id" {
  description = "ID of the resource group"
  value       = azurerm_resource_group.main.id
}

# Networking outputs
output "vnet_id" {
  description = "Virtual Network ID"
  value       = module.networking.vnet_id
}

output "vnet_name" {
  description = "Virtual Network name"
  value       = module.networking.vnet_name
}

# Database outputs
output "database_server_id" {
  description = "MySQL server ID"
  value       = module.database.server_id
}

output "database_server_fqdn" {
  description = "MySQL server FQDN"
  value       = module.database.server_fqdn
}

output "database_name" {
  description = "WordPress database name"
  value       = module.database.database_name
}

# App Service outputs
output "app_service_id" {
  description = "Web App ID"
  value       = module.app_service.id
}

output "app_service_name" {
  description = "Web App name"
  value       = module.app_service.name
}

output "app_service_default_hostname" {
  description = "Web App default hostname"
  value       = module.app_service.default_hostname
}

output "app_service_plan_id" {
  description = "App Service Plan ID"
  value       = module.app_service.plan_id
}

output "staging_slot_hostname" {
  description = "Staging slot hostname"
  value       = module.app_service.staging_slot_hostname
}

# Key Vault outputs
output "key_vault_id" {
  description = "Key Vault ID"
  value       = module.key_vault.id
}

output "key_vault_uri" {
  description = "Key Vault URI"
  value       = module.key_vault.uri
}

# Storage outputs
output "storage_account_name" {
  description = "Storage Account name"
  value       = module.storage.account_name
}

output "storage_blob_endpoint" {
  description = "Storage blob endpoint"
  value       = module.storage.primary_blob_endpoint
}

# Monitoring outputs
output "app_insights_id" {
  description = "Application Insights ID"
  value       = azurerm_application_insights.main.id
}

output "app_insights_name" {
  description = "Application Insights name"
  value       = azurerm_application_insights.main.name
}

output "log_analytics_workspace_id" {
  description = "Log Analytics Workspace ID"
  value       = local.workspace_id
}

# Front Door outputs (conditional)
# NOTE: Uses local.fd_config.enabled which defaults to true via coalesce
output "front_door_endpoint_hostname" {
  description = "Front Door endpoint hostname (for DNS CNAME)"
  value       = local.fd_config.enabled ? module.front_door[0].endpoint_hostname : null
}

output "front_door_profile_id" {
  description = "Front Door profile ID"
  value       = local.fd_config.enabled ? module.front_door[0].profile_id : null
}

output "front_door_resource_guid" {
  description = "Front Door profile resource GUID (for App Service IP restriction)"
  value       = local.fd_config.enabled ? module.front_door[0].resource_guid : null
}

output "custom_domain_validation_token" {
  description = "TXT record value for custom domain validation"
  value       = local.fd_config.enabled ? module.front_door[0].custom_domain_validation_token : null
}

# Cloudflare outputs (conditional)
output "cloudflare_zone_id" {
  description = "Cloudflare zone ID (when cdn_provider = cloudflare)"
  value       = var.cdn_provider == "cloudflare" && length(module.cloudflare) > 0 ? module.cloudflare[0].zone_id : null
}

output "cloudflare_nameservers" {
  description = "Cloudflare nameservers for this zone"
  value       = var.cdn_provider == "cloudflare" && length(module.cloudflare) > 0 ? module.cloudflare[0].nameservers : null
}

output "cloudflare_dns_hostname" {
  description = "DNS hostname managed by Cloudflare"
  value       = var.cdn_provider == "cloudflare" && length(module.cloudflare) > 0 ? module.cloudflare[0].dns_record_hostnames[var.site_name] : null
}

output "cloudflare_proxied" {
  description = "Whether Cloudflare proxy (CDN) is active"
  value       = var.cdn_provider == "cloudflare" && length(module.cloudflare) > 0 ? module.cloudflare[0].proxied_status[var.site_name] : false
}

# CDN provider info
output "cdn_provider" {
  description = "Active CDN provider"
  value       = var.cdn_provider
}

# URLs
output "wordpress_url" {
  description = "WordPress site URL"
  value       = "https://${var.custom_domain}"
}

output "wordpress_admin_url" {
  description = "WordPress admin URL"
  value       = "https://${var.custom_domain}/wp-admin"
}
