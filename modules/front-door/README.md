# Front Door Module

Layer 2 Application module for Azure Front Door CDN + WAF.

## Overview

This module creates:
- Front Door Profile (Premium for WAF)
- Endpoint with custom domain
- Origin group and origin (App Service)
- WAF policy with WordPress exclusions
- Caching rules for static assets

## CRITICAL: WordPress WAF Exclusions

OWASP rules 942230 (SQL injection) and 941320 (XSS) cause false positives
for legitimate WordPress admin operations.

This module automatically configures:
- Exclusions for `wordpress_logged_in_*` cookies
- Exclusions for `wordpress_sec_*` cookies
- Exclusions for `wp-settings-*` cookies
- Rule 942230 and 941320 set to log-only

Without these exclusions, WordPress admin will be blocked.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| site_name | Site name | string | - | yes |
| environment | Environment | string | - | yes |
| resource_group_name | Resource group | string | - | yes |
| sku_name | Front Door SKU | string | "Premium_AzureFrontDoor" | no |
| waf_mode | WAF mode (Detection/Prevention) | string | "Prevention" | no |
| origin_hostname | App Service hostname | string | - | yes |
| custom_domain | Custom domain | string | - | yes |
| cache_uploads_minutes | Cache TTL for uploads | number | 180 | no |
| cache_static_minutes | Cache TTL for static | number | 180 | no |
| tags | Resource tags | map(string) | {} | no |

## Outputs

| Name | Description |
|------|-------------|
| profile_id | Front Door profile ID |
| endpoint_hostname | Front Door endpoint hostname |
| waf_policy_id | WAF policy ID |
| custom_domain_validation_token | TXT record for domain validation |

## Caching Rules

The route lists the module's rule set in `cdn_frontdoor_rule_set_ids`, so Front Door applies these rules to every request through the route, in this order, before the route's own cache settings. Through v4.3.1 the rule set existed but no route listed it, so only the route's own settings applied and admin paths were cached like any other path (#138). The admin rule also sat at order 0, which Azure treats as a global rule whose actions apply to every request; it is now order 1. Taking the release that attaches the set plans in-place updates of the route and of the three rules' orders, nothing else.

| Path | Rule | Cache |
|------|------|-------|
| `wp-admin/*`, `wp-login.php` | `NoCacheAdmin` (order 1, stops further rules) | Disabled |
| `css`, `js`, `jpg`, `jpeg`, `png`, `gif`, `ico`, `woff`, `woff2`, `ttf`, `svg` | `CacheStaticAssets` (order 2) | `cache_static_minutes` (default 180, 3 hours), query string in the cache key |
| `wp-content/uploads/*` | `CacheUploads` (order 3) | `cache_uploads_minutes` (default 180, 3 hours), query string ignored |
| Everything else | route default | Cached, query string in the cache key, compression on |

Front Door honours an origin's `private`, `no-cache` and `no-store` directives even where a rule overrides caching ([Front Door caching](https://learn.microsoft.com/azure/frontdoor/front-door-caching)), so WordPress's own admin responses, which carry `no-cache`, were not stored on earlier releases unless something changed their headers; the rule makes that independent of the origin's headers.

## Usage

```hcl
module "front_door" {
  source = "github.com/agenticcodingops/azure-wordpress//modules/front-door?ref=v4.3.2"

  project_name        = "example"
  site_name           = "examplewp01"
  environment         = "nonprod"
  resource_group_name = azurerm_resource_group.main.name

  origin_hostname = module.app_service.default_hostname
  custom_domain   = "staging.example.com"

  waf_mode = "Detection"  # Use Prevention in production

  tags = local.tags
}
```

## DNS Configuration

After deployment, create CNAME record:
```
{custom_domain} -> {endpoint_hostname}
```

Validation TXT record (for certificate):
```
_dnsauth.{custom_domain} -> {custom_domain_validation_token}
```

## Validation Rules

The module enforces these validations at plan time:

| Variable | Rule | Error Message |
|----------|------|---------------|
| `site_name` | `^[a-z0-9-]+$` | Site name must contain only lowercase letters, numbers, and hyphens |
| `environment` | `nonprod` or `production` | Environment must be 'nonprod' or 'production' |
| `sku_name` | `Standard_AzureFrontDoor` or `Premium_AzureFrontDoor` | SKU must be Standard or Premium |
| `waf_mode` | `Detection` or `Prevention` | WAF mode must be 'Detection' or 'Prevention' |
| `cache_uploads_minutes` | 0-525600 | Cache TTL must be between 0 and 525600 minutes (1 year) |
| `cache_static_minutes` | 0-525600 | Cache TTL must be between 0 and 525600 minutes (1 year) |

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.6.0 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 5.6 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | ~> 5.6 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [azurerm_cdn_frontdoor_custom_domain.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_custom_domain) | resource |
| [azurerm_cdn_frontdoor_custom_domain_association.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_custom_domain_association) | resource |
| [azurerm_cdn_frontdoor_endpoint.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_endpoint) | resource |
| [azurerm_cdn_frontdoor_firewall_policy.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_firewall_policy) | resource |
| [azurerm_cdn_frontdoor_origin.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_origin) | resource |
| [azurerm_cdn_frontdoor_origin_group.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_origin_group) | resource |
| [azurerm_cdn_frontdoor_profile.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_profile) | resource |
| [azurerm_cdn_frontdoor_route.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_route) | resource |
| [azurerm_cdn_frontdoor_rule.cache_static](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_rule) | resource |
| [azurerm_cdn_frontdoor_rule.cache_uploads](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_rule) | resource |
| [azurerm_cdn_frontdoor_rule.no_cache_admin](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_rule) | resource |
| [azurerm_cdn_frontdoor_rule_set.caching](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_rule_set) | resource |
| [azurerm_cdn_frontdoor_security_policy.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_security_policy) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cache_static_minutes"></a> [cache\_static\_minutes](#input\_cache\_static\_minutes) | Cache TTL for static assets in minutes | `number` | `180` | no |
| <a name="input_cache_uploads_minutes"></a> [cache\_uploads\_minutes](#input\_cache\_uploads\_minutes) | Cache TTL for wp-content/uploads in minutes | `number` | `180` | no |
| <a name="input_custom_domain"></a> [custom\_domain](#input\_custom\_domain) | Custom domain for the Front Door endpoint | `string` | n/a | yes |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name (nonprod or production) | `string` | n/a | yes |
| <a name="input_origin_hostname"></a> [origin\_hostname](#input\_origin\_hostname) | Origin hostname (App Service default hostname) | `string` | n/a | yes |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name used in resource naming (lowercase, 2-24 chars) | `string` | n/a | yes |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Name of the resource group | `string` | n/a | yes |
| <a name="input_site_name"></a> [site\_name](#input\_site\_name) | Site name used for resource naming (lowercase, hyphens only) | `string` | n/a | yes |
| <a name="input_sku_name"></a> [sku\_name](#input\_sku\_name) | Front Door SKU (Premium\_AzureFrontDoor required for WAF) | `string` | `"Premium_AzureFrontDoor"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to all resources | `map(string)` | `{}` | no |
| <a name="input_waf_mode"></a> [waf\_mode](#input\_waf\_mode) | WAF mode: Detection (log only) or Prevention (block) | `string` | `"Prevention"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_custom_domain_id"></a> [custom\_domain\_id](#output\_custom\_domain\_id) | ID of the custom domain configuration |
| <a name="output_custom_domain_validation_token"></a> [custom\_domain\_validation\_token](#output\_custom\_domain\_validation\_token) | TXT record value for custom domain validation |
| <a name="output_endpoint_hostname"></a> [endpoint\_hostname](#output\_endpoint\_hostname) | Hostname of the Front Door endpoint (for DNS CNAME) |
| <a name="output_endpoint_id"></a> [endpoint\_id](#output\_endpoint\_id) | ID of the Front Door endpoint |
| <a name="output_profile_id"></a> [profile\_id](#output\_profile\_id) | ID of the Front Door profile |
| <a name="output_profile_name"></a> [profile\_name](#output\_profile\_name) | Name of the Front Door profile |
| <a name="output_resource_guid"></a> [resource\_guid](#output\_resource\_guid) | Resource GUID of the Front Door profile (for App Service x\_azure\_fdid header) |
| <a name="output_waf_policy_id"></a> [waf\_policy\_id](#output\_waf\_policy\_id) | ID of the WAF policy |
<!-- END_TF_DOCS -->
