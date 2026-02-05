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

| Path | Cache Duration | Behavior |
|------|---------------|----------|
| /wp-admin/* | Disabled | No caching for admin |
| /wp-content/uploads/* | 3 hours | Media files |
| *.css, *.js, images | 3 hours | Static assets |
| Other | Default | Query string caching |

## Usage

```hcl
module "front_door" {
  source = "../modules/layer-2-application/front-door"

  site_name           = "workout-tracker"
  environment         = "nonprod"
  resource_group_name = azurerm_resource_group.main.name

  origin_hostname = module.app_service.default_hostname
  custom_domain   = "workout-staging.trackroutinely.com"

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
