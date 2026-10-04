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
| `storage_network_rules_default_action = "Allow"` | The firewall defaults to `Deny`. A storage plugin that points media URLs at the blob endpoint makes **visitors' browsers** fetch media directly from Azure, and with `Deny` those requests 403. `Allow` removes only that firewall gate: the account also disallows anonymous blob access and the uploads container is private, so an anonymous browser still cannot read a blob. See [Media](../../docs/architecture.md#media) and the [security model](../../docs/security-model.md#key-vault-and-storage-deny-public-access-by-default). | Keep `Deny`, the default, while media stays on the app's `/home` storage, which it does unless you install a storage plugin |

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

3. Before you apply, set `WORDPRESS_ADMIN_USER`, `WORDPRESS_ADMIN_EMAIL` and `WORDPRESS_ADMIN_PASSWORD` in
   `app_service.extra_app_settings` in `main.tf`, as in
   [getting started](../../docs/getting-started.md#the-administrator-account). The container then installs
   WordPress itself on first start. Without them the installer is open from the moment the apply finishes, the app
   is reachable on its `*.azurewebsites.net` name, and whoever completes the installer first becomes administrator.

4. Initialize and apply:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

## Cost Estimate

This example uses an App Service plan of SKU B1 and a MySQL server of SKU B_Standard_B2s. Their prices, with
the date and region they were taken for, are in the [cost guide](../../docs/cost.md). Cloudflare plan fees are
outside that table. This example's Cloudflare settings work on the Free plan if the zone has no other page rules:
the site creates three, which is all Free allows per zone. Before you deploy a second site or environment into the
same zone, set `enable_page_rules = false` in its `cloudflare` block. The
[cost guide](../../docs/cost.md#price-table) explains why (note 3).

## SKU Note

With a dedicated plan, the app-service module also creates an autoscale setting on the plan
(`modules/app-service/main.tf:449-450` at v4.1.1). Microsoft documents autoscale for Standard tier and up, and whether
Azure accepts it on a B1 plan has not been tested. If the apply fails on that setting, use `S1`, or a shared
plan as in [`examples/multi-site`](../multi-site/). See
[getting started](../../docs/getting-started.md#the-other-choices).

## Next Steps

- Open the `wordpress_admin_url` output (for example `https://blog.example.com/wp-admin`) and sign in with the
  administrator you set in step 3
- Media uploads stay on the app's `/home` storage by default. The module does not install the Azure Storage plugin,
  and that plugin's unsigned media URLs do not load from this module's storage account; see
  [Media](../../docs/architecture.md#media).
