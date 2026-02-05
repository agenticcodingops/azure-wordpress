# Cloudflare Module - Provider Requirements
# Manages DNS and CDN for WordPress sites using Cloudflare

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = ">= 4.0.0"
    }
  }
}
