# Cloudflare Module - Main Configuration
# Manages DNS records and zone settings for WordPress sites
#
# IMPORTANT: Uses data source for zone since domain is from Cloudflare Registrar
# Zone is automatically created when domain is purchased from Cloudflare Registrar
#
# NOTE: This module is compatible with Cloudflare provider v5.x
# NOTE: Zone settings require enable_zone_setting_overrides = true (may need paid plan)

# ============================================================================
# DATA SOURCES
# ============================================================================

# Lookup existing zone by name using the zones data source
data "cloudflare_zones" "main" {
  name = var.domain
}

# ============================================================================
# LOCAL VARIABLES
# ============================================================================

locals {
  # Get the zone ID from the zones data source
  zone_id = data.cloudflare_zones.main.result[0].id

  # Determine if records should be proxied based on cdn_provider
  # - cloudflare: proxied (orange cloud) - Cloudflare CDN/WAF active
  # - azure_front_door: DNS-only (gray cloud) - Azure Front Door handles CDN
  # - direct: DNS-only (gray cloud) - No CDN, direct to App Service
  use_cloudflare_cdn = var.cdn_provider == "cloudflare"

  # Target hostname depends on cdn_provider
  # - cloudflare/direct: Point to App Service hostname
  # - azure_front_door: Point to Front Door hostname
  site_targets = {
    for site_name, site in var.sites :
    site_name => var.cdn_provider == "azure_front_door" ? lookup(var.front_door_hostnames, site_name, site.origin_hostname) : site.origin_hostname
  }
}

# ============================================================================
# DNS RECORDS (Always created - works on Free plan)
# ============================================================================

# Primary DNS records for each site (apex or subdomain)
resource "cloudflare_dns_record" "site" {
  for_each = var.sites

  zone_id = local.zone_id
  name    = each.value.subdomain != "" ? each.value.subdomain : "@"
  type    = "CNAME"
  content = local.site_targets[each.key]
  proxied = local.use_cloudflare_cdn && each.value.proxied
  ttl     = local.use_cloudflare_cdn && each.value.proxied ? 1 : 300 # Auto TTL when proxied

  comment = "WordPress site: ${each.key} (${each.value.environment})"

  lifecycle {
    # Prevent replacement when zone_id shows as (known after apply) during plan
    # The zone_id never changes for a domain, but data source timing can cause
    # Terraform to think it needs replacement
    ignore_changes = [zone_id]
  }
}

# WWW records for apex domains (redirect www to apex)
resource "cloudflare_dns_record" "www" {
  for_each = {
    for site_name, site in var.sites :
    site_name => site if site.subdomain == ""
  }

  zone_id = local.zone_id
  name    = "www"
  type    = "CNAME"
  content = var.domain # Points to apex
  proxied = local.use_cloudflare_cdn && each.value.proxied
  ttl     = local.use_cloudflare_cdn && each.value.proxied ? 1 : 300

  comment = "WWW redirect for ${each.key}"

  lifecycle {
    ignore_changes = [zone_id]
  }
}

# Front Door validation TXT records (only for azure_front_door mode)
resource "cloudflare_dns_record" "front_door_validation" {
  for_each = var.cdn_provider == "azure_front_door" ? var.front_door_validation_tokens : {}

  zone_id = local.zone_id
  name    = "_dnsauth${var.sites[each.key].subdomain != "" ? ".${var.sites[each.key].subdomain}" : ""}"
  type    = "TXT"
  content = each.value
  ttl     = 300
  proxied = false # TXT records cannot be proxied

  comment = "Front Door domain validation for ${each.key}"

  lifecycle {
    ignore_changes = [zone_id]
  }
}

# Azure App Service domain verification TXT records
# Required for custom hostname binding in Azure App Service
# The TXT record name is: asuid.<subdomain> (or just asuid for apex)
# The value is the App Service custom_domain_verification_id
resource "cloudflare_dns_record" "app_service_verification" {
  for_each = var.app_service_verification_tokens

  zone_id = local.zone_id
  name    = "asuid${var.sites[each.key].subdomain != "" ? ".${var.sites[each.key].subdomain}" : ""}"
  type    = "TXT"
  content = each.value
  ttl     = 300
  proxied = false # TXT records cannot be proxied

  comment = "Azure App Service domain verification for ${each.key}"

  lifecycle {
    ignore_changes = [zone_id]
  }
}

# ============================================================================
# ZONE SETTINGS (Conditional - requires enable_zone_setting_overrides)
# Some settings may not be modifiable on Free plan
# ============================================================================

# SSL/TLS mode: full (strict) validates origin certificate
resource "cloudflare_zone_setting" "ssl" {
  count = var.enable_zone_setting_overrides ? 1 : 0

  zone_id    = local.zone_id
  setting_id = "ssl"
  value      = var.ssl_mode
}

# Minimum TLS version
resource "cloudflare_zone_setting" "min_tls_version" {
  count = var.enable_zone_setting_overrides ? 1 : 0

  zone_id    = local.zone_id
  setting_id = "min_tls_version"
  value      = var.min_tls_version
}

# Always use HTTPS
resource "cloudflare_zone_setting" "always_use_https" {
  count = var.enable_zone_setting_overrides ? 1 : 0

  zone_id    = local.zone_id
  setting_id = "always_use_https"
  value      = "on"
}

# Automatic HTTPS rewrites
resource "cloudflare_zone_setting" "automatic_https_rewrites" {
  count = var.enable_zone_setting_overrides ? 1 : 0

  zone_id    = local.zone_id
  setting_id = "automatic_https_rewrites"
  value      = "on"
}

# Opportunistic Encryption
resource "cloudflare_zone_setting" "opportunistic_encryption" {
  count = var.enable_zone_setting_overrides ? 1 : 0

  zone_id    = local.zone_id
  setting_id = "opportunistic_encryption"
  value      = "on"
}

# Security level
resource "cloudflare_zone_setting" "security_level" {
  count = var.enable_zone_setting_overrides ? 1 : 0

  zone_id    = local.zone_id
  setting_id = "security_level"
  value      = "medium"
}

# Browser check
resource "cloudflare_zone_setting" "browser_check" {
  count = var.enable_zone_setting_overrides ? 1 : 0

  zone_id    = local.zone_id
  setting_id = "browser_check"
  value      = "on"
}

# Browser cache TTL
resource "cloudflare_zone_setting" "browser_cache_ttl" {
  count = var.enable_zone_setting_overrides ? 1 : 0

  zone_id    = local.zone_id
  setting_id = "browser_cache_ttl"
  value      = var.browser_cache_ttl
}

# Cache level
resource "cloudflare_zone_setting" "cache_level" {
  count = var.enable_zone_setting_overrides ? 1 : 0

  zone_id    = local.zone_id
  setting_id = "cache_level"
  value      = "aggressive"
}

# Rocket Loader - OFF for WordPress (breaks JS)
resource "cloudflare_zone_setting" "rocket_loader" {
  count = var.enable_zone_setting_overrides ? 1 : 0

  zone_id    = local.zone_id
  setting_id = "rocket_loader"
  value      = var.enable_wordpress_optimizations ? "off" : "on"
}

# HTTP/2
resource "cloudflare_zone_setting" "http2" {
  count = var.enable_zone_setting_overrides ? 1 : 0

  zone_id    = local.zone_id
  setting_id = "http2"
  value      = "on"
}

# HTTP/3
resource "cloudflare_zone_setting" "http3" {
  count = var.enable_zone_setting_overrides ? 1 : 0

  zone_id    = local.zone_id
  setting_id = "http3"
  value      = "on"
}

# Early Hints
resource "cloudflare_zone_setting" "early_hints" {
  count = var.enable_zone_setting_overrides ? 1 : 0

  zone_id    = local.zone_id
  setting_id = "early_hints"
  value      = "on"
}

# Brotli compression
resource "cloudflare_zone_setting" "brotli" {
  count = var.enable_zone_setting_overrides ? 1 : 0

  zone_id    = local.zone_id
  setting_id = "brotli"
  value      = "on"
}

# 0-RTT for faster TLS connections
resource "cloudflare_zone_setting" "zero_rtt" {
  count = var.enable_zone_setting_overrides ? 1 : 0

  zone_id    = local.zone_id
  setting_id = "0rtt"
  value      = "on"
}
