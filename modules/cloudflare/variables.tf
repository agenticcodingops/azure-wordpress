# Cloudflare Module Variables
# Configures DNS records and CDN settings for WordPress sites

variable "cloudflare_account_id" {
  description = "Cloudflare account ID"
  type        = string
  sensitive   = true
}

variable "domain" {
  description = "Root domain name (e.g., trackroutinely.com)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*\\.[a-z]{2,}$", var.domain))
    error_message = "Domain must be a valid domain name (e.g., example.com)."
  }
}

variable "sites" {
  description = "Map of WordPress sites to configure DNS for"
  type = map(object({
    subdomain       = optional(string, "") # Empty string = apex domain
    origin_hostname = string               # App Service hostname (e.g., app-xxx.azurewebsites.net)
    environment     = string               # nonprod or production
    proxied         = optional(bool, true) # Orange cloud (CDN) or gray cloud (DNS-only)
  }))

  validation {
    condition     = length(keys(var.sites)) > 0
    error_message = "At least one site must be configured."
  }
}

variable "cdn_provider" {
  description = "CDN provider: 'cloudflare' (proxied), 'azure_front_door' (DNS-only), or 'direct' (DNS-only)"
  type        = string
  default     = "cloudflare"

  validation {
    condition     = contains(["cloudflare", "azure_front_door", "direct"], var.cdn_provider)
    error_message = "CDN provider must be 'cloudflare', 'azure_front_door', or 'direct'."
  }
}

# Front Door hostnames for azure_front_door mode
variable "front_door_hostnames" {
  description = "Map of site name to Front Door hostname (required when cdn_provider = azure_front_door)"
  type        = map(string)
  default     = {}
}

# Front Door validation tokens for azure_front_door mode
variable "front_door_validation_tokens" {
  description = "Map of site name to Front Door domain validation token (required when cdn_provider = azure_front_door)"
  type        = map(string)
  default     = {}
}

# Azure App Service domain verification tokens
variable "app_service_verification_tokens" {
  description = "Map of site name to Azure App Service custom domain verification ID (for asuid TXT records)"
  type        = map(string)
  default     = {}
}

# SSL/TLS Settings
variable "ssl_mode" {
  description = "SSL mode: 'strict' (Full strict), 'full', or 'flexible'"
  type        = string
  default     = "strict"

  validation {
    condition     = contains(["strict", "full", "flexible"], var.ssl_mode)
    error_message = "SSL mode must be 'strict', 'full', or 'flexible'. 'strict' is recommended."
  }
}

variable "min_tls_version" {
  description = "Minimum TLS version"
  type        = string
  default     = "1.2"

  validation {
    condition     = contains(["1.0", "1.1", "1.2", "1.3"], var.min_tls_version)
    error_message = "Minimum TLS version must be 1.0, 1.1, 1.2, or 1.3."
  }
}

# WordPress-specific settings
variable "enable_wordpress_optimizations" {
  description = "Enable WordPress-specific optimizations (disable Rocket Loader, JS minification)"
  type        = bool
  default     = true
}

variable "enable_waf" {
  description = "Enable Cloudflare WAF with WordPress exclusions"
  type        = bool
  default     = true
}

variable "enable_page_rules" {
  description = "Enable page rules for WordPress caching (Free plan has 3 rule limit)"
  type        = bool
  default     = true
}

variable "enable_cache_rules" {
  description = "Enable cache rulesets for WordPress (requires paid Cloudflare plan)"
  type        = bool
  default     = false
}

variable "enable_zone_setting_overrides" {
  description = "Enable zone setting overrides like HTTP/2, HTTP/3 (some settings can't be modified on Free plan)"
  type        = bool
  default     = false
}

# Caching settings
variable "browser_cache_ttl" {
  description = "Browser cache TTL in seconds (0 = respect origin headers)"
  type        = number
  default     = 0

  validation {
    condition     = var.browser_cache_ttl >= 0 && var.browser_cache_ttl <= 31536000
    error_message = "Browser cache TTL must be between 0 and 31536000 seconds (1 year)."
  }
}

variable "static_content_cache_ttl" {
  description = "Edge cache TTL for static content in seconds"
  type        = number
  default     = 86400 # 1 day

  validation {
    condition     = var.static_content_cache_ttl >= 0 && var.static_content_cache_ttl <= 2592000
    error_message = "Static content cache TTL must be between 0 and 2592000 seconds (30 days)."
  }
}
