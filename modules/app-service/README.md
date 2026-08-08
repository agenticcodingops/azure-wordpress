# App Service Module

Layer 2 Application module for WordPress on Linux App Service.

## Overview

This module creates:
- Linux Web App with Docker container
- Optional App Service Plan (or use shared)
- Staging deployment slot
- VNet integration for database access
- System-assigned managed identity
- Auto-scale rules

## CRITICAL: No Storage Mount

**DO NOT add `storage_account` block** for `/var/www/html`.

Azure Files mounts cause 2-3 second latency per page load. Instead:
- WordPress is baked into the Docker image (immutable)
- Media uploads use Blob Storage via plugin
- Configuration via app settings (not file mounts)

## Sticky Settings

The following settings are sticky to deployment slots:
- `WP_HOME` - WordPress home URL
- `WP_SITEURL` - WordPress site URL
- `WP_DEBUG` - Debug mode

This ensures staging slot uses staging URL, not production URL.

## SCM/Kudu Network Posture

The SCM endpoint — `https://<app>.scm.azurewebsites.net`, and separately
`https://<app>-staging.scm.azurewebsites.net` for the slot — is **not** covered by the
`ip_restriction` rules that `cdn_provider` drives. It is a distinct gate, and azurerm defaults it
to `Allow`. Kudu offers a shell and read/write access to the persisted `/home` holding WordPress
core, `wp-config.php` and the theme, so until v3.1.0 a site whose public plane admitted only
Cloudflare still had an internet-reachable Kudu, guarded by credentials alone.

Set `scm_ip_restrictions` and `scm_ip_restriction_default_action = "Deny"` to close it. Both apply
to the site **and** its staging slot.

```hcl
scm_ip_restrictions = [
  { ip_address = "203.0.113.10/32", name = "OperatorHome" },
  # A self-hosted runner inside the VNet is better than allow-listing a
  # third party's egress range:
  { virtual_network_subnet_id = azurerm_subnet.runners.id, description = "CI runner" },
]
scm_ip_restriction_default_action = "Deny"
```

Exactly one of `ip_address`, `service_tag` or `virtual_network_subnet_id` must be set per entry —
the module validates this at **plan** time, because azurerm only enforces it during apply. `name`
defaults to `ScmRule-<index>` and `priority` to `100 + <index>`.

### Three things that bite

**1. Network and authentication are independent gates, and both must pass.** Setting the default
action to `Deny` without an allow-list entry that covers you costs the Kudu SSH console even with
valid credentials. That console is Azure's documented route for WP-CLI, and the Microsoft container
ships WordPress 6.6.1 — steady state 6.6.5 after the entrypoint's one-time `wp core update --minor`,
which then disables major auto-update. Getting to a current WordPress is a manual
`wp core update --major` over that console. Lock it out and you lose the only path to a patched
WordPress.

**2. `scm_use_main_ip_restriction` is deliberately not exposed.** azurerm defaults it to `false` and
this module leaves it there. Setting it `true` makes SCM inherit the *main* site's rules — on a
Cloudflare or Front Door site those are CDN egress ranges plus the Azure health probe with `Deny` as
the default, so Kudu becomes unreachable from every operator address. It is the same lockout as (1),
just harder to see coming. Whether it also overrides `scm_ip_restriction_default_action` is
undocumented by Microsoft (verified 2026-08-08), which is a second reason to avoid it. Use an
explicit `scm_ip_restrictions` entry instead.

**3. Terraform itself is unaffected — GitHub-hosted runners are the real problem.** Terraform manages
this app through the ARM control plane, never through Kudu, so tightening SCM does not break
`terraform apply`. But GitHub-hosted runners egress from a wide, rotating range published at
`api.github.com/meta`; allow-listing it admits a large third-party surface for marginal benefit. A
self-hosted runner in the VNet (`virtual_network_subnet_id`) or an Azure-native deploy identity is
the better answer.

Finally, note the provider default is a schema-level `Default`, not "leave Azure alone". Omitting
these arguments materialises `Allow` into state, so an SCM restriction applied by hand in the portal
is reverted on the next apply. Manage it here or it will not stay.

## Publishing Credentials

`ftp_publish_basic_authentication_enabled` and `webdeploy_publish_basic_authentication_enabled` both
default to `true`, matching azurerm. Both are applied to the site **and** the slot — the slot carries
its own independent flags, so a change that misses it still reads as compliant on the site resource
alone.

Setting `webdeploy_publish_basic_authentication_enabled = false` also disables FTP basic auth: Azure
requires SCM basic auth for FTP basic auth. (`site_config.ftps_state` is already `Disabled` here, so
FTP is closed at the transport layer regardless.)

Per [Microsoft's fallback table](https://learn.microsoft.com/en-us/azure/app-service/configure-basic-auth-disable):

| Still works | Breaks |
|---|---|
| `az webapp ssh`, `az webapp create-remote-connection` — Entra fallback, **Azure CLI ≥ 2.48.1** | FTP, local Git |
| Kudu browser UI via Entra SSO | GitHub / Bitbucket / Azure Repos with the *App Service build service* |
| Azure Pipelines via **service connection**; `AzureWebApp` task | Azure Pipelines wired with a *publish profile* |
| GitHub Actions using OIDC / user-assigned identity | Existing GitHub Actions using basic auth |
| Maven and Gradle plugins | `https://<app>.scm.azurewebsites.net/basicauth` |

Two operational preconditions:

- **RBAC.** Browser access to Kudu needs the `Microsoft.Web/sites/publish/Action` operation —
  Website Contributor, Logic Apps Standard Developer, Contributor or Owner. **Reader is not
  sufficient**, with or without basic auth.
- **Azure Policy drift.** Remediation policies exist for both flags
  (`f493116f-3b7f-4ab3-bf80-0c2af35e46c2` for FTP, `2c034a29-2a5f-4857-b120-f800fe5549ae` for SCM).
  A subscription-level assignment will flip them under Terraform and produce perpetual drift; check
  for one before treating the Terraform value as authoritative.

## Usage

```hcl
module "app_service" {
  source = "../modules/layer-2-application/app-service"

  site_name           = "workout-tracker"
  environment         = "nonprod"
  location            = "East US"
  resource_group_name = azurerm_resource_group.main.name

  app_subnet_id = module.networking.app_subnet_id

  database_host     = module.database.server_fqdn
  database_name     = module.database.database_name
  database_username = "wpadmin"

  key_vault_uri                = module.key_vault.uri
  database_password_secret_uri = module.key_vault.secret_versionless_uris["db-password"]

  storage_account_name          = module.storage.account_name
  storage_container_name        = module.storage.container_name
  storage_access_key_secret_uri = module.key_vault.secret_versionless_uris["storage-key"]

  custom_domain = "workout-staging.trackroutinely.com"

  tags = local.tags
}
```

## Deployment Slots

Rolling updates via deployment slots:
1. Deploy to staging slot
2. Test staging slot
3. Swap staging ↔ production
4. Rollback by swapping again

**Requires Standard (S\*) or Premium (P\*).** Basic (B\*) has no deployment slots, and
neither do Free (F1) or Shared (D1) — though `sku_name`'s validation regex rejects those
outright. Detection is an allow-list, `can(regex("^(S|P)[0-9]", var.sku_name))`, so an
unrecognised tier fails closed (no slot created) rather than failing at apply time.

On a Basic plan the slot is silently skipped and the `staging_slot_hostname` and
`staging_slot_principal_id` outputs are `null`. Consumers of the `wordpress-site`
composition module get the same behaviour, driven by `shared_plan_sku` when using a
shared plan.

## Validation Rules

The module enforces these validations at plan time:

| Variable | Rule | Error Message |
|----------|------|---------------|
| `site_name` | `^[a-z0-9-]+$` | Site name must contain only lowercase letters, numbers, and hyphens |
| `environment` | `nonprod` or `production` | Environment must be 'nonprod' or 'production' |
| `sku_name` | `^(B\|S\|P)[0-9]v?[0-9]?$` | SKU must be a valid App Service Plan SKU (e.g., B1, S1, P1v3) |
| `worker_count` | 1-30 | Worker count must be between 1 and 30 |

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.6.0 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 4.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | ~> 4.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [azurerm_linux_web_app.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/linux_web_app) | resource |
| [azurerm_linux_web_app_slot.staging](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/linux_web_app_slot) | resource |
| [azurerm_monitor_autoscale_setting.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_autoscale_setting) | resource |
| [azurerm_service_plan.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/service_plan) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_always_on"></a> [always\_on](#input\_always\_on) | Keep the app always loaded (required for production) | `bool` | `true` | no |
| <a name="input_app_insights_connection_string_secret_uri"></a> [app\_insights\_connection\_string\_secret\_uri](#input\_app\_insights\_connection\_string\_secret\_uri) | Key Vault secret URI for App Insights connection string (versionless) | `string` | `""` | no |
| <a name="input_app_subnet_id"></a> [app\_subnet\_id](#input\_app\_subnet\_id) | ID of the App Service VNet integration subnet (from networking module) | `string` | n/a | yes |
| <a name="input_cdn_provider"></a> [cdn\_provider](#input\_cdn\_provider) | CDN provider for IP restrictions: 'cloudflare', 'azure\_front\_door', 'direct', or 'none' | `string` | `"none"` | no |
| <a name="input_cloudflare_ipv4_cidr_blocks"></a> [cloudflare\_ipv4\_cidr\_blocks](#input\_cloudflare\_ipv4\_cidr\_blocks) | Cloudflare IPv4 CIDR blocks for origin IP restrictions. When null, uses the built-in fallback list. Pass data.cloudflare\_ip\_ranges.current[0].ipv4\_cidrs for live updates. | `list(string)` | `null` | no |
| <a name="input_cloudflare_ipv6_cidr_blocks"></a> [cloudflare\_ipv6\_cidr\_blocks](#input\_cloudflare\_ipv6\_cidr\_blocks) | Cloudflare IPv6 CIDR blocks for origin IP restrictions. When null, uses the built-in fallback list. Pass data.cloudflare\_ip\_ranges.current[0].ipv6\_cidrs for live updates. | `list(string)` | `null` | no |
| <a name="input_custom_domain"></a> [custom\_domain](#input\_custom\_domain) | Custom domain for the WordPress site | `string` | n/a | yes |
| <a name="input_database_host"></a> [database\_host](#input\_database\_host) | MySQL server FQDN | `string` | n/a | yes |
| <a name="input_database_name"></a> [database\_name](#input\_database\_name) | MySQL database name | `string` | n/a | yes |
| <a name="input_database_password_secret_uri"></a> [database\_password\_secret\_uri](#input\_database\_password\_secret\_uri) | Key Vault secret URI for database password (versionless) | `string` | n/a | yes |
| <a name="input_database_username"></a> [database\_username](#input\_database\_username) | MySQL username | `string` | n/a | yes |
| <a name="input_docker_image_tag"></a> [docker\_image\_tag](#input\_docker\_image\_tag) | Tag for the WordPress Docker image | `string` | `"8.4"` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name (nonprod or production) | `string` | n/a | yes |
| <a name="input_extra_app_settings"></a> [extra\_app\_settings](#input\_extra\_app\_settings) | Additional app settings to merge with the default WordPress settings (e.g., WP\_ENVIRONMENT\_TYPE, custom plugin config) | `map(string)` | `{}` | no |
| <a name="input_extra_sticky_app_setting_names"></a> [extra\_sticky\_app\_setting\_names](#input\_extra\_sticky\_app\_setting\_names) | Additional app setting names to mark as sticky (slot-specific, not swapped) | `list(string)` | `[]` | no |
| <a name="input_front_door_enabled"></a> [front\_door\_enabled](#input\_front\_door\_enabled) | DEPRECATED: Use cdn\_provider instead. Whether Front Door is enabled. | `bool` | `true` | no |
| <a name="input_front_door_id"></a> [front\_door\_id](#input\_front\_door\_id) | Azure Front Door resource GUID (required when cdn\_provider = azure\_front\_door) | `string` | `""` | no |
| <a name="input_ftp_publish_basic_authentication_enabled"></a> [ftp\_publish\_basic\_authentication\_enabled](#input\_ftp\_publish\_basic\_authentication\_enabled) | Enable basic authentication for FTP publishing. Defaults to true, matching the azurerm provider default. Note site\_config.ftps\_state is already 'Disabled' here, so FTP is closed at the transport layer regardless. | `bool` | `true` | no |
| <a name="input_health_check_path"></a> [health\_check\_path](#input\_health\_check\_path) | Path for health check endpoint (use a lightweight static file, not the homepage) | `string` | `"/wp-includes/images/blank.gif"` | no |
| <a name="input_key_vault_uri"></a> [key\_vault\_uri](#input\_key\_vault\_uri) | Key Vault URI for secret references | `string` | n/a | yes |
| <a name="input_location"></a> [location](#input\_location) | Azure region for resources | `string` | n/a | yes |
| <a name="input_plan_id"></a> [plan\_id](#input\_plan\_id) | ID of existing App Service Plan. If null, a new plan is created. | `string` | `null` | no |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name used in resource naming (lowercase, 2-24 chars) | `string` | n/a | yes |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Name of the resource group | `string` | n/a | yes |
| <a name="input_scm_ip_restriction_default_action"></a> [scm\_ip\_restriction\_default\_action](#input\_scm\_ip\_restriction\_default\_action) | Default action for SCM/Kudu traffic matching no scm\_ip\_restrictions entry. Defaults to 'Allow', matching the azurerm provider default, so existing consumers see no plan diff. Set to 'Deny' to close Kudu to everything not allow-listed. | `string` | `"Allow"` | no |
| <a name="input_scm_ip_restrictions"></a> [scm\_ip\_restrictions](#input\_scm\_ip\_restrictions) | Allow-list for the SCM/Kudu endpoint. Exactly one of ip\_address, service\_tag or virtual\_network\_subnet\_id must be set per entry. Empty (the default) preserves current provider behaviour. | <pre>list(object({<br/>    ip_address                = optional(string)<br/>    service_tag               = optional(string)<br/>    virtual_network_subnet_id = optional(string)<br/>    name                      = optional(string)<br/>    priority                  = optional(number)<br/>    action                    = optional(string, "Allow")<br/>    description               = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_site_name"></a> [site\_name](#input\_site\_name) | Site name used for resource naming (lowercase, hyphens only) | `string` | n/a | yes |
| <a name="input_sku_name"></a> [sku\_name](#input\_sku\_name) | App Service Plan SKU (P1v3 recommended for production) | `string` | `"P1v3"` | no |
| <a name="input_staging_always_on"></a> [staging\_always\_on](#input\_staging\_always\_on) | Keep the staging slot always loaded (set to false to save cost) | `bool` | `false` | no |
| <a name="input_staging_app_settings_override"></a> [staging\_app\_settings\_override](#input\_staging\_app\_settings\_override) | App settings to override in the staging slot (merged on top of production settings) | `map(string)` | `{}` | no |
| <a name="input_sticky_connection_string_names"></a> [sticky\_connection\_string\_names](#input\_sticky\_connection\_string\_names) | Connection string names to mark as sticky (slot-specific, not swapped) | `list(string)` | `[]` | no |
| <a name="input_storage_access_key_secret_uri"></a> [storage\_access\_key\_secret\_uri](#input\_storage\_access\_key\_secret\_uri) | Key Vault secret URI for storage access key (versionless) | `string` | n/a | yes |
| <a name="input_storage_account_name"></a> [storage\_account\_name](#input\_storage\_account\_name) | Storage account name for media uploads | `string` | n/a | yes |
| <a name="input_storage_container_name"></a> [storage\_container\_name](#input\_storage\_container\_name) | Storage container name for media uploads | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to all resources | `map(string)` | `{}` | no |
| <a name="input_use_shared_plan"></a> [use\_shared\_plan](#input\_use\_shared\_plan) | Set to true when using a shared App Service Plan. This avoids plan-time unknown value issues. | `bool` | `false` | no |
| <a name="input_webdeploy_publish_basic_authentication_enabled"></a> [webdeploy\_publish\_basic\_authentication\_enabled](#input\_webdeploy\_publish\_basic\_authentication\_enabled) | Enable basic authentication for WebDeploy/SCM publishing. Defaults to true, matching the azurerm provider default. Azure requires SCM basic auth for FTP basic auth, so setting this false disables FTP basic auth as well. | `bool` | `true` | no |
| <a name="input_worker_count"></a> [worker\_count](#input\_worker\_count) | Number of workers (instances) | `number` | `1` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_custom_domain_verification_id"></a> [custom\_domain\_verification\_id](#output\_custom\_domain\_verification\_id) | Custom domain verification ID for DNS TXT record (asuid.<subdomain>) |
| <a name="output_default_hostname"></a> [default\_hostname](#output\_default\_hostname) | Default hostname of the Web App |
| <a name="output_id"></a> [id](#output\_id) | ID of the Linux Web App |
| <a name="output_name"></a> [name](#output\_name) | Name of the Linux Web App |
| <a name="output_plan_id"></a> [plan\_id](#output\_plan\_id) | ID of the App Service Plan (created or existing) |
| <a name="output_principal_id"></a> [principal\_id](#output\_principal\_id) | Principal ID of the Web App managed identity |
| <a name="output_staging_slot_hostname"></a> [staging\_slot\_hostname](#output\_staging\_slot\_hostname) | Hostname of the staging deployment slot (null if SKU doesn't support slots) |
| <a name="output_staging_slot_id"></a> [staging\_slot\_id](#output\_staging\_slot\_id) | ID of the staging deployment slot (null if SKU doesn't support slots) |
| <a name="output_staging_slot_principal_id"></a> [staging\_slot\_principal\_id](#output\_staging\_slot\_principal\_id) | Principal ID of the staging slot managed identity (null if SKU doesn't support slots) |
| <a name="output_tenant_id"></a> [tenant\_id](#output\_tenant\_id) | Tenant ID of the Web App managed identity |
<!-- END_TF_DOCS -->
