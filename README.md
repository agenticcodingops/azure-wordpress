# Terraform Azure WordPress

Deploy production-ready WordPress sites on Azure with Cloudflare CDN using Terraform/OpenTofu.

## Features

- **Azure App Service** (Linux) with managed WordPress container
- **Staging Deployment Slots** with configurable app settings and always-on control
- **Azure MySQL Flexible Server** on a delegated subnet with private DNS (no public endpoint)
- **Backup & Recovery** -- configurable PITR retention (1-35 days), geo-redundant backup, storage auto-grow
- **Azure Blob Storage** for media uploads (no Azure Files latency)
- **Blob Protection** -- versioning, soft-delete retention, additional containers (e.g., wp-backups)
- **Storage Lifecycle Management** -- auto-tier to Cool, version/snapshot cleanup on schedule
- **Cloudflare CDN** with DNS management and SSL (cost-optimized)
- **Azure Front Door** alternative with WAF (enterprise option)
- **Key Vault** for secrets management with managed identity (production + staging slots)
- **Application Insights** for monitoring and alerting
- **Shared App Service Plans** for multi-site cost optimization

## Architecture

One call to `modules/wordpress-site` deploys one site:

- **Edge.** `cdn_provider` chooses Cloudflare (`cloudflare`), Azure Front Door (`azure_front_door`) or no CDN
  (`direct`, the default). Only one is created. With a CDN, the web app accepts requests only from it.
- **Web tier.** A Linux web app runs the Microsoft WordPress container, with a staging slot on S\* and P\* SKUs.
  Several sites can share one App Service plan.
- **Database.** MySQL Flexible Server runs on a delegated subnet and is found through a private DNS zone. It has
  no public endpoint. No module in this repository creates a private endpoint.
- **Secrets.** Key Vault holds the database password, the storage key and the Application Insights connection
  string. The web app reads them through Key Vault references, as its managed identity.
- **Media.** Uploads go to Blob Storage through the storage plugin. Browsers then fetch media from the blob
  endpoint directly, not through the CDN.
- **Monitoring.** The site module creates Log Analytics, Application Insights, diagnostic settings and alerts
  itself. It does not use the standalone `monitoring` module.

**[docs/architecture.md](docs/architecture.md)** has the diagrams and the code references for each of these:

- [Container view](docs/architecture.md#container-view)
- [Deployment order](docs/architecture.md#deployment-order), and why Application Insights is created before App Service
- Request flows for [Cloudflare](docs/architecture.md#request-flow-cloudflare) and
  [Azure Front Door](docs/architecture.md#request-flow-azure-front-door)
- [Media](docs/architecture.md#media), [Secrets](docs/architecture.md#secrets),
  [Network](docs/architecture.md#network) and [Monitoring](docs/architecture.md#monitoring)

## Quick Start

### Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.6.0 or [OpenTofu](https://opentofu.org/)
- Azure CLI with active subscription
- Cloudflare account with domain

### Basic Usage

```hcl
module "wordpress_site" {
  # Pin to a release version for stability - see Releases page for latest
  source = "github.com/agenticcodingops/azure-wordpress//modules/wordpress-site?ref=v4.1.0"

  project_name  = "myproject"
  site_name     = "blog"
  environment   = "nonprod"
  location      = "eastus"
  tenant_id     = data.azurerm_client_config.current.tenant_id
  custom_domain = "blog.example.com"

  cdn_provider = "cloudflare"
  cloudflare = {
    enabled    = true
    account_id = var.cloudflare_account_id
    domain     = "example.com"
    subdomain  = "blog"
  }

  # Backup container for UpdraftPlus (v1.1.0+)
  storage = {
    additional_containers = {
      "wp-backups" = { access_type = "private" }
    }
  }

  # Staging slot settings (v1.1.0+)
  app_service = {
    extra_app_settings             = { "WP_ENVIRONMENT_TYPE" = "production" }
    extra_sticky_app_setting_names = ["WP_ENVIRONMENT_TYPE"]
    staging_app_settings_override  = { "WP_ENVIRONMENT_TYPE" = "staging" }
  }
}
```

> **Version pinning:** Always use `?ref=v<VERSION>` to pin to a specific release. Check the [Releases](https://github.com/agenticcodingops/azure-wordpress/releases) page for the latest version. See [Versioning](#versioning) for upgrade guidance.

See [examples/](examples/) for complete configurations.

## Modules

| Module | Description |
|--------|-------------|
| [wordpress-site](modules/wordpress-site/) | Complete WordPress deployment composition |
| [shared-infrastructure](modules/shared-infrastructure/) | Shared App Service Plan for multi-site |
| [app-service](modules/app-service/) | Azure App Service for WordPress |
| [database](modules/database/) | Azure MySQL Flexible Server |
| [storage](modules/storage/) | Azure Blob Storage for media |
| [key-vault](modules/key-vault/) | Azure Key Vault for secrets |
| [networking](modules/networking/) | VNet and subnets |
| [dns-zones](modules/dns-zones/) | Private DNS zones |
| [cloudflare](modules/cloudflare/) | Cloudflare DNS and CDN |
| [front-door](modules/front-door/) | Azure Front Door CDN + WAF |
| [monitoring](modules/monitoring/) | Standalone Application Insights and alerts. `wordpress-site` does not call it |

### Module Composition

- Your configuration calls `wordpress-site` once per site, and `shared-infrastructure` once if sites share a plan.
- `wordpress-site` calls `networking` and `dns-zones` (Layer 1), then `database`, `storage`, `key-vault` and
  `app-service` (Layer 2). After the web app exists it calls `front-door` or `cloudflare`, as `cdn_provider` says.
- `wordpress-site` creates Log Analytics, Application Insights, diagnostic settings, alerts and the action group
  itself. `monitoring` is a standalone module that it does not call.

The order, and the reason for it, is in [Deployment order](docs/architecture.md#deployment-order).

## CDN Options

| Provider | Cost | WAF | SSL | Best For |
|----------|------|-----|-----|----------|
| `cloudflare` | Free tier available | Free | Universal SSL | Cost-optimized deployments |
| `azure_front_door` | ~$35/month base | Included (Premium) | Managed certs | Enterprise, compliance |
| `direct` | None | None | App Service cert | Dev/testing |

## Cost Optimization

### Shared App Service Plans

Deploy multiple WordPress sites on a single App Service Plan:

```hcl
module "shared" {
  source = "github.com/agenticcodingops/azure-wordpress//modules/shared-infrastructure?ref=v4.1.0"

  project_name       = "myproject"
  environment        = "nonprod"
  location           = "eastus"
  app_service_sku    = "B1"  # Start small, scale up as needed
}

module "site1" {
  source = "github.com/agenticcodingops/azure-wordpress//modules/wordpress-site?ref=v4.1.0"

  project_name = "myproject"
  site_name    = "site1"
  # ... other config ...

  app_service = {
    plan_id        = module.shared.app_service_plan_id
    use_shared_plan = true
  }
  shared_resource_group_name = module.shared.resource_group_name
  shared_plan_sku            = "B1"
}
```

**Cost Savings**: ~50% reduction by consolidating plans.

### SKU Recommendations

| Environment | App Service | MySQL | Estimated Cost |
|-------------|-------------|-------|----------------|
| Dev/Test | B1 (shared) | B_Standard_B2s | ~$40/month/site |
| Production | P1v3 (shared) | GP_Standard_D2ds_v4 | ~$150/month/site |

## Security

- **VNet Integration**: App Service reaches MySQL over the virtual network. The server sits on a delegated subnet
  with private DNS and has no public endpoint.
- **Managed Identity**: No credentials stored in code
- **Key Vault References**: Secrets loaded at runtime
- **Firewalls**: Key Vault and Storage deny public data-plane access by default; the App Service subnet is allowed
  through service endpoints
- **IP Restrictions**: With `cloudflare` or `azure_front_door`, the main site accepts only that CDN. The SCM
  (Kudu) endpoint has its own rules and allows all addresses by default
- **TLS 1.2**: Minimum version on the web app, the storage account and the Front Door custom domain. MySQL does
  not require TLS (`require_secure_transport = OFF`)

See [Network](docs/architecture.md#network) for the detail.

## Custom Secrets

The composition module stores three secrets of its own in the site's Key Vault
(`db-password`, `storage-key`, `appinsights-connection`). Consumers can add their own
through `extra_secrets`, and surface them to WordPress as Key Vault references through
`extra_secret_app_settings`:

```hcl
module "wordpress_site" {
  source = "github.com/agenticcodingops/azure-wordpress//modules/wordpress-site?ref=v4.1.0"

  # ... other configuration ...

  extra_secrets = {
    "smtp-password" = var.smtp_relay_password
  }

  extra_secret_app_settings = {
    "SMTP_PASSWORD" = "smtp-password"
  }
}
```

The module resolves `smtp-password` to
`@Microsoft.KeyVault(SecretUri=https://<vault>/secrets/smtp-password)` internally and applies
it to both the production app and the staging slot. Both managed identities already hold
`Get`/`List` on secrets at vault scope, so nothing else is needed.

Build the reference inside the module rather than in your own configuration: doing it
consumer-side needs the module's `key_vault_uri` output fed back into that same module's
input, which Terraform rejects as a self-referential cycle. The
`key_vault_secret_versionless_uris` output is available if you need the URIs elsewhere.

Module-owned secret names always win on collision, so `extra_secrets` cannot clobber the
database password. Keys must be known at plan time.

## Outbound Email (SMTP relay)

**WordPress on App Service cannot send mail out of the box.** Azure blocks outbound port 25
on all App Service plans, and the Linux WordPress container ships no MTA — `wp_mail()` fails
silently, taking password resets, comment notifications and order confirmations with it.

Use an authenticated relay on port 587 and an SMTP plugin (WP Mail SMTP, Post SMTP, or
`WP_MAIL_SMTP` constants). Keep the password in Key Vault rather than in `wp-config.php` or
the plugin's database row:

```hcl
extra_secrets = {
  "smtp-password" = var.smtp_relay_password # e.g. a Google Workspace relay credential
}

app_service = {
  extra_app_settings = {
    "SMTP_HOST"       = "smtp-relay.gmail.com"
    "SMTP_PORT"       = "587"
    "SMTP_SECURE"     = "tls"
    "SMTP_AUTH"       = "true"
    "SMTP_USERNAME"   = "wordpress@example.com"
    "SMTP_FROM"       = "wordpress@example.com"
    "SMTP_FROM_NAME"  = "Example Site"
  }
}

extra_secret_app_settings = {
  "SMTP_PASSWORD" = "smtp-password"
}
```

Notes:

- **Port 25 is blocked and will not be unblocked.** Relays that only accept 25 will not work.
- The exact setting names depend on which SMTP plugin you use — the module passes them
  through verbatim and does not interpret them.
- Google Workspace SMTP relay additionally requires the sending domain to be authorised in
  the Workspace admin console; allow-listing by IP is impractical because App Service
  outbound IPs change when the plan scales.
- Add SPF/DKIM records for the relay to your DNS or mail will land in spam.

## Backup & Recovery

### MySQL Point-in-Time Recovery (PITR)

Configure via the `database` variable:

```hcl
database = {
  backup_retention_days     = 14                  # 1-35 days (default: 30 for production, 7 for nonprod)
  geo_redundant_backup      = true                # Cross-region backup (default: true for production)
  storage_auto_grow_enabled = true                # Auto-grow storage when capacity is low (default: true)
}
```

The composition module applies environment-aware defaults: production gets 30-day retention
with geo-redundant backup enabled automatically.

> **Changed in v2.0.0.** These defaults were dead code through v1.3.2 — the object
> attributes carried non-null `optional()` defaults, so the environment branch never ran
> and every environment got 7-day retention with geo-redundancy off. They now work as
> documented. **If you rely on backups staying in one region, set
> `geo_redundant_backup = false` explicitly**, because production now enables it.

### Environment-aware Defaults

Set any of these explicitly and your value is used; leave it unset and the value below applies.

| Setting | Production | Nonprod | Changing it later |
|---|---|---|---|
| `database.sku_name` | `GP_Standard_D2ds_v4` | `B_Standard_B2s` | in-place resize, 60-120s restart |
| `database.backup_retention_days` | 30 | 7 | online |
| `database.geo_redundant_backup` | `true` | `false` | **replaces the server** |
| `front_door.waf_mode` | `Prevention` | `Detection` | in-place |
| `monitoring.retention_days` | 90 | 30 | in-place |
| `app_service.health_check_path` | `/wp-includes/images/blank.gif` | same | in-place |
| `key_vault_purge_protection_enabled` | `true` | `false` | in-place to enable; **replaces the vault** to disable |
| `key_vault_soft_delete_retention_days` | 90 | 7 | **replaces the vault** |

> **`geo_redundant_backup` is create-time only.** Azure can only choose geo-redundancy when
> the MySQL Flexible Server is created, so azurerm marks it `ForceNew` — changing it on an
> existing server produces a plan that **destroys and recreates it, losing all data**, and
> `modules/database` sets `prevent_destroy = false`.
>
> This matters when **upgrading an existing v1.x deployment that never set the attribute**:
> it was effectively `false` before and becomes `true` in production here. Set it explicitly
> to `false` before upgrading, or take a backup and accept the replacement. New deployments
> on v2.0.0+ are unaffected — the server is simply created with geo-redundancy on.
>
> **The two Key Vault settings are effectively create-time only — in one direction.** Purge
> protection can be turned *on* in place, but never off; the retention window cannot be
> updated at all. So the new nonprod values (`false`/`7`) are unreachable on an existing
> vault and plan a **destroy and recreate**, while *hardening* a nonprod vault later is a
> free in-place update. Upgrading an existing **nonprod** deployment that leaves both inputs
> unset therefore replaces its vault, and the apply fails unless
> `key_vault_name_suffix` is bumped in the same change — the soft-deleted vault still holds
> the name, and the provider would recover it rather than create a new one. Set both to
> `true`/`90` to keep the old behaviour. See
> [`modules/wordpress-site/README.md`](modules/wordpress-site/README.md#️-upgrading-to-v300--read-before-you-apply).

### Blob Storage Protection

Configure via the `storage` variable:

```hcl
storage = {
  versioning_enabled              = true          # Point-in-time recovery for blobs (default: true)
  blob_delete_retention_days      = 30            # Soft-delete for blobs (default: 30)
  container_delete_retention_days = 30            # Soft-delete for containers (default: 30)

  # Additional containers (e.g., for UpdraftPlus backup plugin)
  additional_containers = {
    "wp-backups" = { access_type = "private" }
  }
}
```

### Storage Lifecycle Management

Automatically tier and clean up old data to reduce costs:

```hcl
storage = {
  lifecycle_policy_enabled       = true           # Enable lifecycle rules (default: true)
  lifecycle_cool_tier_days       = 30             # Move to Cool tier after N days (default: 30)
  lifecycle_version_delete_days  = 90             # Delete old versions after N days (default: 90)
  lifecycle_snapshot_delete_days = 90             # Delete old snapshots after N days (default: 90)
  lifecycle_prefix_match         = ["uploads/"]   # Scope to specific prefixes (default: ["uploads/"])
}
```

## Staging Deployment Slots

The App Service module creates a staging deployment slot automatically on Standard (S\*)
and Premium (P\*) SKUs. Basic tier (B\*) does not support slots.

### Configuring Staging

```hcl
app_service = {
  sku_name = "P1v3"  # Must be Standard or Premium for slot support

  # Add custom app settings (merged with built-in WordPress settings)
  extra_app_settings = {
    "WP_ENVIRONMENT_TYPE" = "production"
  }

  # Mark settings as sticky (slot-specific, not swapped)
  extra_sticky_app_setting_names = ["WP_ENVIRONMENT_TYPE"]

  # Override settings on the staging slot
  staging_app_settings_override = {
    "WP_ENVIRONMENT_TYPE" = "staging"
  }

  # Save cost by not keeping staging always loaded
  staging_always_on = false
}
```

### Built-in Slot Behavior

The module automatically handles these -- do NOT duplicate them in `extra_app_settings`:

| Setting | Production Value | Staging Value | Sticky? |
|---------|-----------------|---------------|---------|
| `WP_HOME` | `https://{custom_domain}` | `https://app-{name}-staging.azurewebsites.net` | Yes |
| `WP_SITEURL` | `https://{custom_domain}` | `https://app-{name}-staging.azurewebsites.net` | Yes |
| `WP_DEBUG` | `false` | `true` | Yes |
| `DATABASE_*` | Key Vault reference | Same as production | No |
| `MICROSOFT_AZURE_*` | Key Vault reference | Same as production | No |

### Key Vault Access

Both production and staging slot managed identities are granted Key Vault `Get`/`List`
access automatically, so `@Microsoft.KeyVault(SecretUri=...)` references resolve on both slots.

To grant the site access to resources this module does **not** own (your own Key Vault,
a storage account, a Service Bus namespace), use the exported principal IDs directly
rather than re-reading the app with a `data "azurerm_linux_web_app"` block:

```hcl
resource "azurerm_key_vault_access_policy" "shared" {
  key_vault_id       = azurerm_key_vault.shared.id
  tenant_id          = data.azurerm_client_config.current.tenant_id
  object_id          = module.wordpress_site.app_service_principal_id
  secret_permissions = ["Get", "List"]
}
```

`staging_slot_principal_id` is exported the same way — but do **not** drive `count` from it.
It is `null` on SKUs without slots (B-tier), yet on S\*/P\* tiers it is *unknown* until the
slot is created, and Terraform rejects any plan whose `count` is unknown. Guard on the SKU
you configured instead, which is known at plan time and mirrors the module's own
`local.sku_supports_slots`:

Declare the SKU once and feed both the module and the `count`, so the two cannot drift:

```hcl
locals {
  app_service_sku = "P1v3"
}

module "wordpress_site" {
  # ...
  app_service = { sku_name = local.app_service_sku }
}

resource "azurerm_key_vault_access_policy" "shared_staging" {
  # Known at plan time. Mirrors the module's own local.sku_supports_slots.
  count = can(regex("^(S|P)[0-9]", local.app_service_sku)) ? 1 : 0

  key_vault_id       = azurerm_key_vault.shared.id
  tenant_id          = data.azurerm_client_config.current.tenant_id
  object_id          = module.wordpress_site.staging_slot_principal_id
  secret_permissions = ["Get", "List"]
}
```

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.6.0 |
| azurerm | ~> 5.6 |
| azapi | >= 1.13.0, < 3.0 |
| cloudflare | ~> 5.0 |
| random | >= 3.5.0, < 4.0 |
| time | >= 0.9.0, < 1.0 |
| null | >= 3.2.0, < 4.0 |

## Versioning

This project uses [Semantic Versioning](https://semver.org/) with automated releases. All modules are versioned together as a single unit.

### Pinning to a Version

Always pin module references to a specific version tag to prevent unexpected changes:

```hcl
module "wordpress" {
  source = "github.com/agenticcodingops/azure-wordpress//modules/wordpress-site?ref=v4.1.0"
  # ...
}
```

Available versions are listed on the [Releases](https://github.com/agenticcodingops/azure-wordpress/releases) page.

### Upgrading from v3 to v4

v4.0.0 moves every module onto azurerm `~> 5.6`. The root module must require that same constraint, or `terraform init` cannot resolve a provider. No module inputs change. Run `terraform plan` before the first apply. Key Vault purge protection, soft-delete retention, and MySQL geo-redundant backup are unchanged by this release, and each of them is costly to change after the resource exists.

The provider no longer registers resource providers unless asked: `resource_provider_registrations` defaults to `none`, and `skip_provider_registration` is removed. Set `resource_provider_registrations = "legacy"` to keep the previous automatic set. Plan-time location and resource-provider checks also default off. Set `features.enhanced_validation.locations` and `features.enhanced_validation.resource_providers` to `true` to keep catching those at plan time. The examples set all three.

### Upgrading Versions

1. Check the [CHANGELOG](CHANGELOG.md) for the target version
2. Look for **BREAKING CHANGES** — these require configuration updates
3. Update the `?ref=` tag in all module source URLs
4. Run `terraform init -upgrade` to fetch the new version
5. Run `terraform plan` to review changes before applying

### Version Guarantees

| Version Change | Guarantee |
|---|---|
| **PATCH** (v1.0.0 → v1.0.1) | Bug fixes only. No input/output changes. Safe to upgrade. |
| **MINOR** (v1.0.0 → v1.1.0) | New features with backward compatibility. Existing configs work unchanged. |
| **MAJOR** (v1.0.0 → v2.0.0) | Breaking changes. Review CHANGELOG and update your configuration. |

**One exception, in v4.1.0:** the container image default changes from `"8.4"` to the floating `"8.3"`, so a
configuration that never set the image tag plans an in-place `docker_image_name` update on the app (and, on S*/P*
plans, the staging slot). `"8.4"` does not exist on the registry as a floating tag (measured 2026-09-27; the 8.4 series is
published only as dated tags), so the old default cannot survive a restart. Set `wordpress_version` (or `docker_image_tag` on the app-service module) explicitly to keep your
current value. See the site module's "Upgrading to v4.1.0".

## Contributing

Contributions are welcome! Please read our [contributing guidelines](CONTRIBUTING.md) before submitting PRs.

## License

Apache License 2.0 - see [LICENSE](LICENSE) for details.
