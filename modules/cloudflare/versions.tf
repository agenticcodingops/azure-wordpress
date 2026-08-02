# Cloudflare Module - Provider Requirements
# Manages DNS and CDN for WordPress sites using Cloudflare

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    # Constrained to 5.x. The data.cloudflare_ip_ranges attributes were renamed
    # between majors - 4.x exposes ipv4_cidr_blocks/ipv6_cidr_blocks, 5.x exposes
    # ipv4_cidrs/ipv6_cidrs - and this repo uses the 5.x names. Without an upper
    # bound a consumer resolving 4.x fails with "Unsupported attribute".
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}
