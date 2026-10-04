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

1. **An existing Cloudflare zone for `domain`** - The module looks the zone up by name (`data.cloudflare_zones`)
   and never creates it. Add the domain to Cloudflare before you apply.
2. **Cloudflare API token** scoped to this zone (plus the two account-level permissions under Cache Rules, if you enable them), with:
   - Zone > Zone > Read: the `data.cloudflare_zones` lookup
   - Zone > DNS > Edit: the site, `www` and `asuid` records, plus `_dnsauth` in `azure_front_door` mode
   - Zone > Page Rules > Edit: the three page rules (`enable_page_rules`, default `true`)
   - Zone > Zone WAF > Edit: the three WAF rulesets (`enable_waf`, default `true` in this module, `false` when called through `wordpress-site`)
   - Zone > Cache Rules > Edit: the cache ruleset (`enable_cache_rules`, default `false`). Cloudflare's Cache Rules API page lists three required permissions: this one, Account > Account Rulesets > Edit and Account > Account Filter Lists > Edit. The last two are account-level, so a zone-scoped token does not carry them. Add them when you turn this flag on. Whether an apply fails without them has not been tried.
   - Zone > Zone Settings > Edit: the zone settings, including the SSL/TLS mode (`enable_zone_setting_overrides`, default `false`)

   Leave out a permission whose flag is off. The list does not need SSL and Certificates or Firewall Services. The module manages no certificates, the SSL/TLS mode is a zone setting, and Cloudflare documents Zone WAF, not Firewall Services, as the permission for zone rulesets in the WAF phases.

## Usage

```hcl
module "cloudflare" {
  source = "github.com/agenticcodingops/azure-wordpress//modules/cloudflare?ref=v4.1.1"

  cloudflare_account_id = var.cloudflare_account_id
  domain                = "example.com"
  cdn_provider          = "cloudflare"

  sites = {
    "example-prod" = {
      subdomain       = "" # Apex domain
      origin_hostname = "app-example-site-prod.azurewebsites.net"
      environment     = "production"
      proxied         = true
    }
    "example-staging" = {
      subdomain       = "staging"
      origin_hostname = "app-example-site-np.azurewebsites.net"
      environment     = "nonprod"
      proxied         = true
    }
  }

  enable_waf                     = false # keep false unless the zone is on Business or higher; see Cost
  enable_page_rules              = true
  enable_wordpress_optimizations = true # inert unless enable_zone_setting_overrides = true
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `cloudflare_account_id` | Cloudflare account ID | `string` | - | Yes |
| `domain` | Root domain name | `string` | - | Yes |
| `sites` | Map of WordPress sites | `map(object)` | - | Yes |
| `cdn_provider` | CDN mode: cloudflare, azure_front_door, direct | `string` | `"cloudflare"` | No |
| `ssl_mode` | SSL mode: strict, full, flexible. Applied only with `enable_zone_setting_overrides = true` | `string` | `"strict"` | No |
| `min_tls_version` | Minimum TLS version. Applied only with `enable_zone_setting_overrides = true` | `string` | `"1.2"` | No |
| `enable_waf` | Enable the WordPress WAF rulesets (see Cost) | `bool` | `true` | No |
| `enable_page_rules` | Enable WordPress page rules | `bool` | `true` | No |
| `enable_wordpress_optimizations` | With `enable_zone_setting_overrides = true`: Rocket Loader off (`true`) or on (`false`). No effect otherwise | `bool` | `true` | No |
| `enable_zone_setting_overrides` | Manage the zone settings listed under WordPress Optimizations | `bool` | `false` | No |
| `enable_cache_rules` | Enable the WordPress cache ruleset (Cache Rules) | `bool` | `false` | No |
| `app_service_verification_tokens` | Map of site name to App Service custom domain verification ID (for `asuid` TXT records) | `map(string)` | `{}` | No |
| `browser_cache_ttl` | Browser cache TTL (seconds). Applied only with `enable_zone_setting_overrides = true` | `number` | `0` | No |
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
| `ssl_mode` | SSL mode applied to the zone when `enable_zone_setting_overrides = true` |
| `cdn_provider` | Active CDN provider |

## WordPress Optimizations

`enable_wordpress_optimizations` takes effect only when `enable_zone_setting_overrides = true` (default `false`). It then sets the zone's Rocket Loader setting: `off` when `true`, and `on` when `false`. With overrides off, the module leaves Rocket Loader as the zone has it.

With `enable_zone_setting_overrides = true` the module also manages these zone settings (some cannot be changed on the Free plan):

- SSL mode (`ssl_mode`) and minimum TLS (`min_tls_version`)
- Always Use HTTPS, Automatic HTTPS Rewrites and Opportunistic Encryption
- security level `medium` and Browser Integrity Check
- browser cache TTL (`browser_cache_ttl`) and cache level `aggressive`
- HTTP/2, HTTP/3, Early Hints, Brotli and 0-RTT

The module manages no minification setting; Cloudflare deprecated Auto Minify on 5 August 2024.

Cache bypass for `wp-admin` and `wp-login.php` comes from the page rules (`enable_page_rules`, default `true`), not from this flag. The opt-in cache ruleset (`enable_cache_rules`, default `false`) also bypasses `wp-cron.php`, `/wp-json/` and logged-in users.

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

The module sets the zone-wide mode from `ssl_mode` only when `enable_zone_setting_overrides = true`; otherwise the zone keeps its own mode. Separately, the three page rules (`enable_page_rules`, default `true`) set `ssl = strict` on `/wp-admin/*`, `/wp-login.php*` and `/wp-content/*` whatever `ssl_mode` says.

| Mode | Description | Recommendation |
|------|-------------|----------------|
| `strict` | Validates origin certificate | **Production** |
| `full` | Encrypts but doesn't validate | Development |
| `flexible` | HTTPS to CF, HTTP to origin | **Not recommended** |

## Switching CDN providers (standalone use of this module)

**Through `modules/wordpress-site` this does not apply.** There, this module runs only when `cdn_provider = "cloudflare"` and `cloudflare.enabled = true`. Changing `cdn_provider` to `"azure_front_door"` therefore destroys the site's Cloudflare records and rules: the CNAME, `www` for an apex site, the `asuid` TXT, the page rules, and any rulesets and zone settings. It creates no record for Front Door. The same apply also limits the web app to Front Door traffic. Treat the switch as a cutover with downtime. After the apply:

1. Create a CNAME from the custom domain to the `front_door_endpoint_hostname` output. **Who:** operator. **STOP:** yes, a DNS change.
2. Create a `_dnsauth.<subdomain>` TXT record (`_dnsauth` for an apex domain) with the `custom_domain_validation_token` output as its value. **Who:** operator. **STOP:** yes, a DNS change.
3. The site is down until Front Door shows the domain **Approved** and has deployed its managed certificate (minutes to an hour, sometimes longer). **Who:** operator. **STOP:** no, this is a wait.

Read the plan before you apply. See [Request flow: Azure Front Door](../../docs/architecture.md#request-flow-azure-front-door).

**Standalone**, set all three inputs:

```hcl
cdn_provider = "azure_front_door"
front_door_hostnames = {
  "example-prod" = "example-prod-abcdefghijklmnop.z01.azurefd.net" # front-door module output endpoint_hostname
}
front_door_validation_tokens = {
  "example-prod" = "<validation token>" # front-door module output custom_domain_validation_token
}
```

This turns proxying off (gray cloud), points each listed site's CNAME at its Front Door host, and creates a `_dnsauth` TXT record for each site that has a token. A site missing from `front_door_hostnames` stays pointed at its `origin_hostname`, unproxied. Without `front_door_validation_tokens`, no TXT record is created and Front Door never validates the domain.

The module creates the `_dnsauth` record only in this mode, so it lands in the same apply that moves the CNAME, and the domain does not serve until validation completes. To avoid that gap, create the `_dnsauth` TXT yourself before switching. Wait until the domain shows Approved, then switch and leave `front_door_validation_tokens` empty, so the module does not create a duplicate record.

## Cost

With `enable_waf = false`, the module fits the Cloudflare Free plan. It uses all three of Free's page rules, and the optional cache ruleset uses 5 of the 10 cache rules Free allows.

`enable_waf` defaults to `true` in this module, so set it to `false` unless the zone is on Business or higher. The login rate-limit rule matches on the request method (`waf.tf:101-104`), and Cloudflare offers the Method field in rate-limiting rules only from Business upward. Free also allows just one rate-limit rule, with a 10 s counting period and a 10 s timeout.

Business is necessary but not yet sufficient. Both rate-limit rules set `characteristics = ["ip.src"]` (`waf.tf:96`, `:113`) without `cf.colo.id`. Cloudflare's rate-limiting parameters reference marks `cf.colo.id` as mandatory for API users, so expect `cloudflare_ruleset.wordpress_rate_limit` to be rejected until the module adds it. This has not been tried on a live zone. Keep `enable_waf = false` until then.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.6.0 |
| <a name="requirement_cloudflare"></a> [cloudflare](#requirement\_cloudflare) | ~> 5.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_cloudflare"></a> [cloudflare](#provider\_cloudflare) | ~> 5.0 |

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
| <a name="input_domain"></a> [domain](#input\_domain) | Root domain name (e.g., example.com) | `string` | n/a | yes |
| <a name="input_enable_cache_rules"></a> [enable\_cache\_rules](#input\_enable\_cache\_rules) | Enable the WordPress cache ruleset (Cache Rules). Available on every plan, including Free, which allows 10 cache rules; the ruleset uses 5 | `bool` | `false` | no |
| <a name="input_enable_page_rules"></a> [enable\_page\_rules](#input\_enable\_page\_rules) | Enable page rules for WordPress caching (Free plan has 3 rule limit) | `bool` | `true` | no |
| <a name="input_enable_waf"></a> [enable\_waf](#input\_enable\_waf) | Enable the WordPress WAF rulesets: managed-rule exceptions, rate limiting and custom security rules. Needs Cloudflare Business or higher: the login rate-limit rule matches on the request method (http.request.method), which rate-limiting rules allow from Business upward. Pro's other limits (2 rules, periods up to 1 min, timeouts up to 1 h) fit; Free allows 1 rule with a 10 s period and timeout | `bool` | `true` | no |
| <a name="input_enable_wordpress_optimizations"></a> [enable\_wordpress\_optimizations](#input\_enable\_wordpress\_optimizations) | With enable\_zone\_setting\_overrides = true, sets Rocket Loader off (true) or on (false). No effect otherwise | `bool` | `true` | no |
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
