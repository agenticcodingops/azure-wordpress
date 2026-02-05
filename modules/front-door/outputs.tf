# Front Door Module Outputs
# These outputs are used for DNS configuration and monitoring

output "profile_id" {
  description = "ID of the Front Door profile"
  value       = azurerm_cdn_frontdoor_profile.main.id
}

output "profile_name" {
  description = "Name of the Front Door profile"
  value       = azurerm_cdn_frontdoor_profile.main.name
}

output "resource_guid" {
  description = "Resource GUID of the Front Door profile (for App Service x_azure_fdid header)"
  value       = azurerm_cdn_frontdoor_profile.main.resource_guid
}

output "endpoint_id" {
  description = "ID of the Front Door endpoint"
  value       = azurerm_cdn_frontdoor_endpoint.main.id
}

output "endpoint_hostname" {
  description = "Hostname of the Front Door endpoint (for DNS CNAME)"
  value       = azurerm_cdn_frontdoor_endpoint.main.host_name
}

output "waf_policy_id" {
  description = "ID of the WAF policy"
  value       = azurerm_cdn_frontdoor_firewall_policy.main.id
}

output "custom_domain_id" {
  description = "ID of the custom domain configuration"
  value       = azurerm_cdn_frontdoor_custom_domain.main.id
}

output "custom_domain_validation_token" {
  description = "TXT record value for custom domain validation"
  value       = azurerm_cdn_frontdoor_custom_domain.main.validation_token
}
