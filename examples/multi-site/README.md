# Multi-Site WordPress Example

Deploy multiple WordPress sites sharing a single App Service Plan for cost optimization.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│           Shared Resource Group                         │
│  ┌───────────────────────────────────────────────────┐  │
│  │         Shared App Service Plan (B1/P1v3)         │  │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐  │  │
│  │  │  main-site  │ │    blog     │ │    docs     │  │  │
│  │  │  WordPress  │ │  WordPress  │ │  WordPress  │  │  │
│  │  └─────────────┘ └─────────────┘ └─────────────┘  │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│       Per-Site Resource Groups (Isolated)               │
│  ┌─────────────────┐  ┌─────────────────┐              │
│  │ MySQL (site 1)  │  │ MySQL (site 2)  │  ...         │
│  │ Storage         │  │ Storage         │              │
│  │ Key Vault       │  │ Key Vault       │              │
│  │ VNet            │  │ VNet            │              │
│  └─────────────────┘  └─────────────────┘              │
└─────────────────────────────────────────────────────────┘
```

## Cost Comparison

A shared plan is paid once; each site still pays for its own MySQL server, storage, Key Vault and DNS zone. The
[cost guide](../../docs/cost.md#2-estimate-a-shared-plan) compares dedicated and shared plans for three sites,
with dated prices.

## Cloudflare Page Rules

Every site creates three Cloudflare page rules, and their URLs are built from the zone's domain, so they match every
host in the zone. The Free plan allows three page rules per zone, so this example's three sites in one zone make
the second site's apply fail on Free. Set `enable_page_rules = false` in the
`cloudflare` block of all but one site, and keep it `true` on the site that should hold the rules. Removing that
site removes the rules for all three. See note 3 of the [cost guide](../../docs/cost.md#price-table).

## Version Pinning

This example pins module sources to a specific release tag (`?ref=v4.1.0`). To use a different version:

1. Check available versions on the [Releases](https://github.com/agenticcodingops/azure-wordpress/releases) page
2. Update the `?ref=` tag for **both** `shared-infrastructure` and `wordpress-site` modules in `main.tf`
3. Run `terraform init -upgrade` to fetch the new version

> **Important:** Always use the same version tag for all modules to ensure compatibility.

## Network Access Defaults

From v2.0.0 Key Vault and Storage deny public data-plane access by default, so this example
sets `key_vault_public_network_access_enabled = true` and
`storage_network_rules_default_action = "Allow"` on every site. Without the first, the first
apply 403s creating vault secrets. The storage firewall defaults to `Deny`; `Allow` removes only
that gate for browsers that fetch media from the blob endpoint, because the account also
disallows anonymous blob access and the uploads container is private. Media stays on each app's
`/home` storage by default; see [Media](../../docs/architecture.md#media). Both inputs are
applied per site inside the `for_each`, so every site in `var.sites` gets them. See
[`examples/basic-site/README.md`](../basic-site/README.md#network-access-defaults) for the
rationale and the tighter IP-allow-list alternative.

From v3.0.0 Key Vault purge protection and soft-delete retention default by environment
(`true`/90 production, `false`/7 nonprod). Because these are applied per site, adopting
v3.0.0 on an existing **nonprod** multi-site deployment replaces **every** site's vault —
each one needs its `key_vault_name_suffix` bumped, or both inputs pinned to `true`/`90`.

## Usage

1. Copy and configure variables:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars with your values
   ```

2. Deploy:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

Before you apply, set `WORDPRESS_ADMIN_USER`, `WORDPRESS_ADMIN_EMAIL` and `WORDPRESS_ADMIN_PASSWORD` in each
site's `app_service.extra_app_settings`, as in
[getting started](../../docs/getting-started.md#the-administrator-account), so no site leaves the WordPress
installer open to whoever reaches it first.

## Scaling

- **Add sites**: Add entries to `sites` map in terraform.tfvars
- **Remove sites**: Remove entries, after backing up and removing any locks. See
  [step 12 of the deployment guide](../../docs/deployment-guide.md#step-12-remove-a-site)
- **Scale up**: Change `app_service_sku` (e.g., B1 → P1v3)

## Capacity

How many sites one plan can carry has not been measured. It depends on traffic, plugins and PHP memory (256 MB per
worker). Watch the plan's CPU and memory after each site you add; see the
[cost guide](../../docs/cost.md#2-estimate-a-shared-plan).
