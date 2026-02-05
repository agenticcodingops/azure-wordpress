# Cloudflare Module

Manages DNS records, CDN settings, and WAF rules for WordPress sites using Cloudflare.

**Provider Compatibility:** Cloudflare provider v5.x

## Overview

This module configures Cloudflare as the DNS provider and optionally as the CDN/WAF for WordPress sites. It supports three modes:

| Mode | Description | Proxied | CDN/WAF |
|------|-------------|---------|---------|
| `cloudflare` | Full Cloudflare CDN/WAF | Yes (orange cloud) | Cloudflare |
| `azure_front_door` | DNS-only, Azure CDN | No (gray cloud) | Azure Front Door |
| `direct` | DNS-only, no CDN | No (gray cloud) | None |

## Prerequisites

1. **Domain registered with Cloudflare Registrar** - Zone is created automatically
2. **Cloudflare API Token** with permissions:
   - Zone:DNS:Edit
   - Zone:Zone:Read
   - Zone:SSL and Certificates:Edit
   - Zone:Firewall Services:Edit (if WAF enabled)

## Usage

```hcl
module "cloudflare" {
  source = "../../modules/cloudflare"

  cloudflare_account_id = var.cloudflare_account_id
  domain                = "trackroutinely.com"
  cdn_provider          = "cloudflare"

  sites = {
    "trackroutinely-prod" = {
      subdomain       = ""                                    # Apex domain
      origin_hostname = "app-trackroutinely-trackroutinely-prod.azurewebsites.net"
      environment     = "production"
      proxied         = true
    }
    "trackroutinely-staging" = {
      subdomain       = "staging"
      origin_hostname = "app-trackroutinely-trackroutinely-np.azurewebsites.net"
      environment     = "nonprod"
      proxied         = true
    }
  }

  enable_waf                     = true
  enable_page_rules              = true
  enable_wordpress_optimizations = true
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `cloudflare_account_id` | Cloudflare account ID | `string` | - | Yes |
| `domain` | Root domain name | `string` | - | Yes |
| `sites` | Map of WordPress sites | `map(object)` | - | Yes |
| `cdn_provider` | CDN mode: cloudflare, azure_front_door, direct | `string` | `"cloudflare"` | No |
| `ssl_mode` | SSL mode: strict, full, flexible | `string` | `"strict"` | No |
| `min_tls_version` | Minimum TLS version | `string` | `"1.2"` | No |
| `enable_waf` | Enable Cloudflare WAF | `bool` | `true` | No |
| `enable_page_rules` | Enable WordPress page rules | `bool` | `true` | No |
| `enable_wordpress_optimizations` | Disable features that break WordPress | `bool` | `true` | No |
| `browser_cache_ttl` | Browser cache TTL (seconds) | `number` | `0` | No |
| `static_content_cache_ttl` | Edge cache TTL for static content | `number` | `86400` | No |
| `front_door_hostnames` | Front Door hostnames (azure_front_door mode) | `map(string)` | `{}` | No |
| `front_door_validation_tokens` | Front Door validation tokens | `map(string)` | `{}` | No |

## Outputs

| Name | Description |
|------|-------------|
| `zone_id` | Cloudflare zone ID |
| `zone_name` | Domain name |
| `nameservers` | Cloudflare nameservers |
| `dns_record_ids` | Map of record names to IDs |
| `dns_record_hostnames` | Map of site names to hostnames |
| `proxied_status` | Map of site names to proxied status |
| `ssl_mode` | Current SSL mode |
| `cdn_provider` | Active CDN provider |

## WordPress Optimizations

When `enable_wordpress_optimizations = true`, the module:

1. **Disables Rocket Loader** - Breaks WordPress JavaScript
2. **Disables JS Minification** - Can break WordPress themes/plugins
3. **Enables HTML/CSS Minification** - Safe for WordPress
4. **Configures WordPress-aware caching** - Bypasses cache for admin/login

## WAF Rules

When `enable_waf = true`, the module creates:

1. **WAF Exceptions** for WordPress admin paths
2. **Rate Limiting** for wp-login.php and xmlrpc.php
3. **Security Rules** blocking common attack patterns

### Excluded Paths

- `/wp-admin/*` - WordPress admin
- `/wp-login.php` - Login page
- `/wp-cron.php` - WordPress cron
- `/wp-json/*` - REST API (when authenticated)

### Protected Paths

- `wp-config.php` - Blocked
- `.htaccess` - Blocked
- PHP in uploads - Blocked

## Page Rules

Free plan includes 3 page rules:

1. **wp-admin/*** - Bypass cache, high security
2. **wp-login.php*** - Bypass cache, high security
3. **wp-content/*** - Cache everything, 1 day TTL

## SSL Modes

| Mode | Description | Recommendation |
|------|-------------|----------------|
| `strict` | Validates origin certificate | **Production** |
| `full` | Encrypts but doesn't validate | Development |
| `flexible` | HTTPS to CF, HTTP to origin | **Not recommended** |

## Switching CDN Providers

To switch from Cloudflare CDN to Azure Front Door:

```hcl
# Change in terraform.tfvars
cdn_provider = "azure_front_door"

# Provide Front Door hostnames
front_door_hostnames = {
  "trackroutinely-prod" = "trackroutinely-prod.azurefd.net"
}
```

This will:
1. Change DNS records to gray cloud (DNS-only)
2. Create TXT records for Front Door domain validation
3. Point CNAME to Front Door instead of App Service

## Cost

Cloudflare Free plan includes:
- Unlimited DNS records
- Universal SSL
- Basic WAF
- 3 Page Rules
- CDN/caching
- DDoS protection

No additional cost for this module on Free plan.
