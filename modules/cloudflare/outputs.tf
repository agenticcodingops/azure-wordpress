# Cloudflare Module Outputs
# Compatible with Cloudflare provider v5.x

output "zone_id" {
  description = "Cloudflare zone ID"
  value       = local.zone_id
}

output "zone_name" {
  description = "Cloudflare zone name (domain)"
  value       = var.domain
}

output "nameservers" {
  description = "Cloudflare nameservers for this zone"
  value       = try(data.cloudflare_zones.main.result[0].name_servers, [])
}

output "dns_record_ids" {
  description = "Map of DNS record names to their IDs"
  value = merge(
    { for k, v in cloudflare_dns_record.site : k => v.id },
    { for k, v in cloudflare_dns_record.www : k => v.id }
  )
}

output "dns_record_hostnames" {
  description = "Map of site names to their full hostnames"
  value = {
    for site_name, site in var.sites :
    site_name => site.subdomain != "" ? "${site.subdomain}.${var.domain}" : var.domain
  }
}

output "proxied_status" {
  description = "Map of site names to their proxied status (true = Cloudflare CDN active)"
  value = {
    for site_name, record in cloudflare_dns_record.site :
    site_name => record.proxied
  }
}

output "ssl_mode" {
  description = "Current SSL mode for the zone"
  value       = var.ssl_mode
}

output "cdn_provider" {
  description = "Active CDN provider"
  value       = var.cdn_provider
}

output "app_service_verification_record_ids" {
  description = "Map of site names to their App Service verification TXT record IDs"
  value = {
    for site_name, record in cloudflare_dns_record.app_service_verification :
    site_name => record.id
  }
}

output "site_record_ids" {
  description = "Map of site names to their CNAME record IDs"
  value = {
    for site_name, record in cloudflare_dns_record.site :
    site_name => record.id
  }
}
