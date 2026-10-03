# Basic WordPress Site Example

Deploy a single WordPress site with Cloudflare CDN on Azure.

## Prerequisites

1. Azure subscription with Owner or Contributor access
2. Cloudflare account with a registered domain
3. Terraform >= 1.6.0

## Version Pinning

This example pins module sources to a specific release tag (`?ref=v4.1.0`). To use a different version:

1. Check available versions on the [Releases](https://github.com/agenticcodingops/azure-wordpress/releases) page
2. Update the `?ref=` tag in `main.tf`
3. Run `terraform init -upgrade` to fetch the new version

## Network Access Defaults

From v2.0.0 both Key Vault and Storage **deny public data-plane access by default**, so this
example sets two inputs explicitly that a minimal config would otherwise omit:

| Input | Why it is set | Tighter alternative |
|---|---|---|
| `key_vault_public_network_access_enabled = true` | Terraform is not a trusted Azure service, so creating the vault's secrets 403s unless the deploying principal can reach it. Hosted CI runners have a rotating egress range that cannot be allow-listed. | `key_vault_network_acls_ip_rules = ["<runner IP>"]` on a self-hosted runner with a stable IP |
| `storage_network_rules_default_action = "Allow"` | The WordPress Blob Storage plugin points media URLs at the blob endpoint, so **visitors' browsers** fetch media directly from Azure. With `Deny`, every image 403s site-wide — not just the deploy. | Keep `Deny` only if the blob endpoint is fronted by a CDN custom domain |

From v3.0.0, Key Vault purge protection and soft-delete retention default by environment —
`true`/90 in production, `false`/7 in nonprod, so a destroyed nonprod vault's name is
immediately reusable. Both are commented in `main.tf` if you need the old behaviour; see
[the module upgrade notes](../../modules/wordpress-site/README.md) before changing them on
an existing deployment, because they force a vault replacement.

## Quick Start

1. Copy the example variables file:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Edit `terraform.tfvars` with your values

3. Initialize and apply:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

## Cost Estimate

This example uses an App Service plan of SKU B1 and a MySQL server of SKU B_Standard_B2s. Their prices, with
the date and region they were taken for, are in the [cost guide](../../docs/cost.md). Cloudflare plan fees are
outside that table; this example's Cloudflare settings work on the Free plan.

## SKU Note

With a dedicated plan, the app-service module also creates an autoscale setting on the plan
(`modules/app-service/main.tf:449-450` at v4.1.1). Microsoft documents autoscale for Standard tier and up, and whether
Azure accepts it on a B1 plan has not been tested. If the apply fails on that setting, use `S1`, or a shared
plan as in [`examples/multi-site`](../multi-site/). See
[getting started](../../docs/getting-started.md#the-other-choices).

## Next Steps

- Access WordPress admin at `https://your-domain.com/wp-admin`
- Default credentials are set during first visit
- Configure Azure Storage plugin for media uploads
