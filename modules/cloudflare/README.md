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

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.6.0 |
| <a name="requirement_cloudflare"></a> [cloudflare](#requirement\_cloudflare) | >= 4.0.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_cloudflare"></a> [cloudflare](#provider\_cloudflare) | >= 4.0.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [cloudflare_dns_record.app_service_verification](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/dns_record) | resource |
| [cloudflare_dns_record.front_door_validation](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/dns_record) | resource |
| [cloudflare_dns_record.site](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/dns_record) | resource |
| [cloudflare_dns_record.www](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/dns_record) | resource |
| [cloudflare_page_rule.wp_admin](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/page_rule) | resource |
| [cloudflare_page_rule.wp_content](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/page_rule) | resource |
| [cloudflare_page_rule.wp_login](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/page_rule) | resource |
| [cloudflare_ruleset.wordpress_cache](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/ruleset) | resource |
| [cloudflare_ruleset.wordpress_rate_limit](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/ruleset) | resource |
| [cloudflare_ruleset.wordpress_security](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/ruleset) | resource |
| [cloudflare_ruleset.wordpress_waf_exceptions](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/ruleset) | resource |
| [cloudflare_zone_setting.always_use_https](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zone_setting) | resource |
| [cloudflare_zone_setting.automatic_https_rewrites](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zone_setting) | resource |
| [cloudflare_zone_setting.brotli](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zone_setting) | resource |
| [cloudflare_zone_setting.browser_cache_ttl](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zone_setting) | resource |
| [cloudflare_zone_setting.browser_check](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zone_setting) | resource |
| [cloudflare_zone_setting.cache_level](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zone_setting) | resource |
| [cloudflare_zone_setting.early_hints](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zone_setting) | resource |
| [cloudflare_zone_setting.http2](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zone_setting) | resource |
| [cloudflare_zone_setting.http3](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zone_setting) | resource |
| [cloudflare_zone_setting.min_tls_version](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zone_setting) | resource |
| [cloudflare_zone_setting.opportunistic_encryption](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zone_setting) | resource |
| [cloudflare_zone_setting.rocket_loader](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zone_setting) | resource |
| [cloudflare_zone_setting.security_level](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zone_setting) | resource |
| [cloudflare_zone_setting.ssl](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zone_setting) | resource |
| [cloudflare_zone_setting.zero_rtt](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zone_setting) | resource |
| [cloudflare_zones.main](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/data-sources/zones) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_app_service_verification_tokens"></a> [app\_service\_verification\_tokens](#input\_app\_service\_verification\_tokens) | Map of site name to Azure App Service custom domain verification ID (for asuid TXT records) | `map(string)` | `{}` | no |
| <a name="input_browser_cache_ttl"></a> [browser\_cache\_ttl](#input\_browser\_cache\_ttl) | Browser cache TTL in seconds (0 = respect origin headers) | `number` | `0` | no |
| <a name="input_cdn_provider"></a> [cdn\_provider](#input\_cdn\_provider) | CDN provider: 'cloudflare' (proxied), 'azure\_front\_door' (DNS-only), or 'direct' (DNS-only) | `string` | `"cloudflare"` | no |
| <a name="input_cloudflare_account_id"></a> [cloudflare\_account\_id](#input\_cloudflare\_account\_id) | Cloudflare account ID | `string` | n/a | yes |
| <a name="input_domain"></a> [domain](#input\_domain) | Root domain name (e.g., trackroutinely.com) | `string` | n/a | yes |
| <a name="input_enable_cache_rules"></a> [enable\_cache\_rules](#input\_enable\_cache\_rules) | Enable cache rulesets for WordPress (requires paid Cloudflare plan) | `bool` | `false` | no |
| <a name="input_enable_page_rules"></a> [enable\_page\_rules](#input\_enable\_page\_rules) | Enable page rules for WordPress caching (Free plan has 3 rule limit) | `bool` | `true` | no |
| <a name="input_enable_waf"></a> [enable\_waf](#input\_enable\_waf) | Enable Cloudflare WAF with WordPress exclusions | `bool` | `true` | no |
| <a name="input_enable_wordpress_optimizations"></a> [enable\_wordpress\_optimizations](#input\_enable\_wordpress\_optimizations) | Enable WordPress-specific optimizations (disable Rocket Loader, JS minification) | `bool` | `true` | no |
| <a name="input_enable_zone_setting_overrides"></a> [enable\_zone\_setting\_overrides](#input\_enable\_zone\_setting\_overrides) | Enable zone setting overrides like HTTP/2, HTTP/3 (some settings can't be modified on Free plan) | `bool` | `false` | no |
| <a name="input_front_door_hostnames"></a> [front\_door\_hostnames](#input\_front\_door\_hostnames) | Map of site name to Front Door hostname (required when cdn\_provider = azure\_front\_door) | `map(string)` | `{}` | no |
| <a name="input_front_door_validation_tokens"></a> [front\_door\_validation\_tokens](#input\_front\_door\_validation\_tokens) | Map of site name to Front Door domain validation token (required when cdn\_provider = azure\_front\_door) | `map(string)` | `{}` | no |
| <a name="input_min_tls_version"></a> [min\_tls\_version](#input\_min\_tls\_version) | Minimum TLS version | `string` | `"1.2"` | no |
| <a name="input_sites"></a> [sites](#input\_sites) | Map of WordPress sites to configure DNS for | <pre>map(object({<br/>    subdomain       = optional(string, "") # Empty string = apex domain<br/>    origin_hostname = string               # App Service hostname (e.g., app-xxx.azurewebsites.net)<br/>    environment     = string               # nonprod or production<br/>    proxied         = optional(bool, true) # Orange cloud (CDN) or gray cloud (DNS-only)<br/>  }))</pre> | n/a | yes |
| <a name="input_ssl_mode"></a> [ssl\_mode](#input\_ssl\_mode) | SSL mode: 'strict' (Full strict), 'full', or 'flexible' | `string` | `"strict"` | no |
| <a name="input_static_content_cache_ttl"></a> [static\_content\_cache\_ttl](#input\_static\_content\_cache\_ttl) | Edge cache TTL for static content in seconds | `number` | `86400` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_app_service_verification_record_ids"></a> [app\_service\_verification\_record\_ids](#output\_app\_service\_verification\_record\_ids) | Map of site names to their App Service verification TXT record IDs |
| <a name="output_cdn_provider"></a> [cdn\_provider](#output\_cdn\_provider) | Active CDN provider |
| <a name="output_dns_record_hostnames"></a> [dns\_record\_hostnames](#output\_dns\_record\_hostnames) | Map of site names to their full hostnames |
| <a name="output_dns_record_ids"></a> [dns\_record\_ids](#output\_dns\_record\_ids) | Map of DNS record names to their IDs |
| <a name="output_nameservers"></a> [nameservers](#output\_nameservers) | Cloudflare nameservers for this zone |
| <a name="output_proxied_status"></a> [proxied\_status](#output\_proxied\_status) | Map of site names to their proxied status (true = Cloudflare CDN active) |
| <a name="output_site_record_ids"></a> [site\_record\_ids](#output\_site\_record\_ids) | Map of site names to their CNAME record IDs |
| <a name="output_ssl_mode"></a> [ssl\_mode](#output\_ssl\_mode) | Current SSL mode for the zone |
| <a name="output_zone_id"></a> [zone\_id](#output\_zone\_id) | Cloudflare zone ID |
| <a name="output_zone_name"></a> [zone\_name](#output\_zone\_name) | Cloudflare zone name (domain) |
<!-- END_TF_DOCS -->
