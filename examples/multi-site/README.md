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

| Deployment | Sites | App Service Plans | Est. Monthly Cost |
|------------|-------|-------------------|-------------------|
| Dedicated plans | 3 | 3 x B1 ($13) | $39 + $75 (MySQL) = ~$114 |
| **Shared plan** | 3 | 1 x B1 ($13) | $13 + $75 (MySQL) = ~$88 |

**Savings: ~23% with 3 sites, increases with more sites**

## Version Pinning

This example pins module sources to a specific release tag (`?ref=v3.0.0`). To use a different version:

1. Check available versions on the [Releases](https://github.com/agenticcodingops/azure-wordpress/releases) page
2. Update the `?ref=` tag for **both** `shared-infrastructure` and `wordpress-site` modules in `main.tf`
3. Run `terraform init -upgrade` to fetch the new version

> **Important:** Always use the same version tag for all modules to ensure compatibility.

## Network Access Defaults

From v2.0.0 Key Vault and Storage deny public data-plane access by default, so this example
sets `key_vault_public_network_access_enabled = true` and
`storage_network_rules_default_action = "Allow"` on every site — without them the first
apply 403s creating vault secrets, and site media 403s for visitors. Both are applied per
site inside the `for_each`, so every site in `var.sites` gets them. See
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

## Scaling

- **Add sites**: Add entries to `sites` map in terraform.tfvars
- **Remove sites**: Remove entries (7-day soft delete enabled)
- **Scale up**: Change `app_service_sku` (e.g., B1 → P1v3)

## Capacity Guidelines

| SKU | Max Sites | Use Case |
|-----|-----------|----------|
| B1 | 2-3 | Development, low traffic |
| P1v3 | 8-10 | Production, moderate traffic |
| P2v3 | 15+ | High traffic |

Monitor CPU/memory in Azure Portal and scale when needed.
