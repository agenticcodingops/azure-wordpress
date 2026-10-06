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
  (`direct`, the default). Only one is created. Cloudflare records and rules also need `cloudflare.enabled = true`.
  With a CDN, the main site denies traffic that matches no rule. With Cloudflare it allows Cloudflare's address
  ranges, which every Cloudflare account shares, so they admit Cloudflare and not only your zone, and Azure's
  `168.63.129.16` address. With Front Door and `front_door.enabled` true (the default), a patch
  that runs after Front Door is created narrows it to your own Front Door profile and drops the `168.63.129.16`
  rule. The web app resource does not ignore that change, so a later apply is expected to restore the module's own
  rules: any Front Door profile, with no `X-Azure-FDID` check, plus `168.63.129.16`. Nothing guarantees that the
  patch runs again. Review the web app's plan before every apply; see
  [Request flow: Azure Front Door](docs/architecture.md#request-flow-azure-front-door). With `azure_front_door`,
  the staging slot is not patched: it accepts any Front Door profile and keeps the `168.63.129.16` rule. With
  `cloudflare` or `direct`, it has the main site's rules. The SCM (Kudu) endpoints of the web app and the slot have
  their own rules and allow all addresses by default; see [Network](docs/architecture.md#network).
- **Web tier.** A Linux web app runs the Microsoft WordPress container, with a staging slot on S\* and P\* SKUs.
  Several sites can share one App Service plan.
- **Database.** MySQL Flexible Server runs on a delegated subnet and is found through a private DNS zone. It has
  no public endpoint. No module in this repository creates a private endpoint.
- **Secrets.** Key Vault holds the database password, the storage key and the Application Insights connection
  string. The web app reads them through Key Vault references, as its managed identity.
- **Media.** By default WordPress writes uploads to the web app's persistent `/home` storage, not to Blob Storage.
  They move to Blob Storage only after you install the Microsoft Azure Storage for WordPress plugin and make it
  the default upload target. That plugin points media URLs at the blob endpoint, so browsers fetch media from Azure
  directly, not through the CDN. The storage firewall defaults to `Deny`, and setting `Allow` is not enough on
  its own: the account also disallows anonymous blob access and the uploads container is private, so an unsigned
  media URL still fails. See [Media](docs/architecture.md#media).
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
  source = "github.com/agenticcodingops/azure-wordpress//modules/wordpress-site?ref=v4.1.1"

  project_name  = "myproject"
  site_name     = "examplewp01" # change me: Key Vault and storage names derive from this and must be globally unique
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

  # Key Vault and Storage deny public data-plane access by default.
  # Terraform writes the vault's secrets itself and is not a trusted Azure service,
  # so from a hosted CI runner the first apply fails with a Key Vault 403 unless
  # the vault is reachable. On a runner with a fixed egress IP, use
  # key_vault_network_acls_ip_rules = ["<runner IP>"] instead.
  key_vault_public_network_access_enabled = true
  # The storage firewall defaults to "Deny", which suits the default setup: uploads stay
  # on the app's /home storage. Only if you serve media from the blob endpoint (after you
  # install the storage plugin) do visitors' browsers meet the firewall and get 403, and
  # "Allow" removes that gate. It is not enough on its own: the account disallows
  # anonymous blob access and the uploads container is private, so an unsigned media
  # URL still fails (docs/architecture.md#media). Test an uploaded file in a signed-out
  # browser before you rely on it.
  # storage_network_rules_default_action = "Allow"

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

- **First deployment:** [docs/getting-started.md](docs/getting-started.md) is the smallest configuration that
  applies from CI, with no CDN and no DNS, and explains the two network inputs above.
- **Production pattern:** [docs/deployment-guide.md](docs/deployment-guide.md) covers remote state, OIDC from CI,
  provider pins, locks, staging slots, shared plans, and adding and removing sites.
- **Cost:** [docs/cost.md](docs/cost.md) has the dated price table.

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
  `app-service` (Layer 2). It also calls `front-door` (with `cdn_provider = "azure_front_door"` and
  `front_door.enabled`, default true) or `cloudflare` (with `cdn_provider = "cloudflare"` and
  `cloudflare.enabled = true`; the default is false). Front Door and the Cloudflare DNS records wait for the web app.
- `wordpress-site` creates Log Analytics, Application Insights, diagnostic settings, alerts and the action group
  itself. `monitoring` is a standalone module that it does not call.

The order, and the reason for it, is in [Deployment order](docs/architecture.md#deployment-order).

## CDN Options

| Provider | Cost | WAF | SSL | Best For |
|----------|------|-----|-----|----------|
| `cloudflare` | Free tier available (see the [cost guide](docs/cost.md), note 3) | Cloudflare's free managed rules; the module's `enable_waf` rulesets need Business or higher and, until the rate-limit rules add `cf.colo.id`, cannot be relied on ([details](docs/security-model.md#waf-rules-beyond-what-the-cdn-plan-provides)) | Universal SSL | Cost-optimized deployments |
| `azure_front_door` | Premium monthly base fee: the module's WAF policy needs Premium (see [cost guide](docs/cost.md)) | Included (Premium) | Managed certs | Enterprise, compliance |
| `direct` | None | None | Platform `*.azurewebsites.net` cert on the default host name only; a custom domain gets no certificate, so bind your own ([TLS settings](docs/security-model.md#tls-settings)) | Dev/testing |

## Cost Optimization

### Shared App Service Plans

Deploy multiple WordPress sites on a single App Service Plan:

```hcl
module "shared" {
  source = "github.com/agenticcodingops/azure-wordpress//modules/shared-infrastructure?ref=v4.1.1"

  project_name       = "myproject"
  environment        = "nonprod"
  location           = "eastus"
  app_service_sku    = "B1"  # Start small, scale up as needed
}

module "site1" {
  source = "github.com/agenticcodingops/azure-wordpress//modules/wordpress-site?ref=v4.1.1"

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

For an existing site, switching to `use_shared_plan = true` replaces the web app and is expected to fail;
migrate instead. See
[step 11 of the deployment guide](docs/deployment-guide.md#step-11-host-several-sites-on-a-shared-plan).

**Cost savings:** the plan is paid once instead of once per site. Each site still pays for its own MySQL server.
See the [cost guide](docs/cost.md#2-estimate-a-shared-plan) for a worked comparison.

### SKU Recommendations

| Environment | App Service | MySQL |
|-------------|-------------|-------|
| Dev/Test | B1 (shared) | B_Standard_B2s |
| Production | P1v3 (shared) | GP_Standard_D2ds_v4 |

Prices for each SKU, with their date and region, are in the [cost guide](docs/cost.md).

## Security

- **VNet Integration**: App Service reaches MySQL over the virtual network. The server sits on a delegated subnet
  with private DNS and has no public endpoint.
- **Managed Identity**: No credentials stored in code
- **Key Vault References**: Secrets loaded at runtime
- **Firewalls**: Key Vault and Storage deny public data-plane access by default; the App Service subnet is allowed
  through service endpoints
- **IP Restrictions**: With `cloudflare`, the main site accepts Cloudflare's address ranges, which every Cloudflare
  account shares, and Azure's `168.63.129.16` address. With `azure_front_door` and `front_door.enabled` true (the
  default), the patch applied after Front Door is created makes it accept only your Front Door profile and drops
  the `168.63.129.16` rule. A later apply is expected to restore the module's own rules (any Front Door profile, plus `168.63.129.16`), and nothing
  guarantees the patch runs again. The staging slot accepts any Front Door profile. With
  `front_door.enabled = false`, both accept any Front Door profile, and the main site keeps the
  `168.63.129.16` rule. The SCM (Kudu) endpoint has its own rules and allows all addresses by default
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
  source = "github.com/agenticcodingops/azure-wordpress//modules/wordpress-site?ref=v4.1.1"

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
> [v2 to v3](docs/upgrading/v2-to-v3.md).

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
| `WP_DEBUG` | `true` in nonprod, `false` in production | `true` | Yes |
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
  source = "github.com/agenticcodingops/azure-wordpress//modules/wordpress-site?ref=v4.1.1"
  # ...
}
```

Available versions are listed on the [Releases](https://github.com/agenticcodingops/azure-wordpress/releases) page.

### Upgrading

See the [upgrade guide](docs/upgrading/README.md).

### Version Guarantees

| Version Change | Guarantee |
|---|---|
| **PATCH** (v1.0.0 → v1.0.1) | Bug fixes only. No input/output changes. Safe to upgrade. |
| **MINOR** (v1.0.0 → v1.1.0) | New features with backward compatibility. Existing configs work unchanged. |
| **MAJOR** (v1.0.0 → v2.0.0) | Breaking changes. Review CHANGELOG and update your configuration. |

The v4.1.0 image-default exception is in [4.0 to 4.1](docs/upgrading/v4.0-to-v4.1.md).

## Contributing

Contributions are welcome! Please read our [contributing guidelines](CONTRIBUTING.md) before submitting PRs.

## License

Apache License 2.0 - see [LICENSE](LICENSE) for details.
