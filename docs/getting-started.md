# Getting started

## Purpose

Deploy one non-production WordPress site from a CI pipeline, with the smallest configuration that applies
cleanly. It needs no CDN account and no DNS changes: the site is served on the App Service's own
`*.azurewebsites.net` name.

Code references are `file:line` at commit
[`9cf59db`](https://github.com/agenticcodingops/azure-wordpress/tree/9cf59dbf1f984a2e043cd7b6180187dda8cfcd5a),
which is release v4.1.1.

## When to use

- Your first deployment of this module.
- An evaluation or test site.

Do **not** use this configuration for production as it stands. It has no CDN, so the origin accepts traffic from
anywhere (`modules/app-service/main.tf:258`). For production, read the [deployment guide](deployment-guide.md)
and choose a CDN; [`examples/basic-site`](../examples/basic-site/) shows Cloudflare.

## Prerequisites

- **An Azure subscription** where the deploying identity has **Contributor** at subscription scope. The module
  creates its own resource group (`modules/wordpress-site/main.tf:185-188`), so a role scoped to one resource
  group is not enough.
- **Remote state and an OIDC identity for CI.** Set these up with steps 1 and 2 of the
  [deployment guide](deployment-guide.md).
- **Terraform 1.6.0 or later** (`modules/wordpress-site/main.tf:15`). The module's own CI uses 1.9.8, and the
  configuration below was tested on 1.9.8.
- **Outbound access from the runner:**
  - `github.com`, for the module source;
  - `registry.terraform.io`, and the hosts it sends provider downloads to: `releases.hashicorp.com` for the
    HashiCorp providers, and GitHub release downloads for `azapi` and `cloudflare`;
  - Microsoft Entra ID, Azure Resource Manager, the state account's blob endpoint and the new vault's data plane.

## The configuration

`main.tf`:

```hcl
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.6"
    }
  }

  # Remote state. The values come from backend.hcl at `terraform init`.
  backend "azurerm" {}
}

# The subscription, tenant and identity come from the ARM_* environment variables.
provider "azurerm" {
  resource_provider_registrations = "legacy"

  features {}
}

data "azurerm_client_config" "current" {}

locals {
  project_name = "example"     # change me
  site_name    = "examplewp01" # change me: see "Names that must be unique"
}

module "wordpress" {
  source = "github.com/agenticcodingops/azure-wordpress//modules/wordpress-site?ref=v4.1.1"

  project_name = local.project_name
  site_name    = local.site_name
  environment  = "nonprod"
  location     = "eastus"
  tenant_id    = data.azurerm_client_config.current.tenant_id

  # No CDN and no DNS: serve the site on the app's own *.azurewebsites.net name.
  cdn_provider  = "direct"
  custom_domain = "app-${local.project_name}-${local.site_name}-np.azurewebsites.net"

  # The two network inputs a first apply from a hosted CI runner needs.
  key_vault_public_network_access_enabled = true
  storage_network_rules_default_action    = "Allow"

  app_service = {
    sku_name = "S1"
  }
}

output "wordpress_url" {
  value = module.wordpress.wordpress_url
}

output "app_service_default_hostname" {
  value = module.wordpress.app_service_default_hostname
}
```

`backend.hcl` (no secrets in it, so you can commit it):

```hcl
resource_group_name  = "rg-tfstate-example"
storage_account_name = "sttfstateexample"
container_name       = "tfstate"
key                  = "wordpress/nonprod.tfstate"
use_azuread_auth     = true
```

`use_azuread_auth` makes the backend sign in to the state account with Microsoft Entra ID. It is needed because
the state account in the deployment guide has shared-key access turned off.

### The two network inputs

Key Vault and Storage deny public data-plane access by default. Both defaults break a first deployment, in
different ways.

| Input | Default | What fails with the default | Why this guide sets it | Tighter option |
|---|---|---|---|---|
| `key_vault_public_network_access_enabled = true` | `false` (`modules/wordpress-site/variables.tf:130-134`), which sets the vault firewall's `default_action` to `Deny` (`modules/key-vault/main.tf:54-59`) | **The apply.** Terraform writes three secrets into the vault (`modules/wordpress-site/main.tf:377-381`, `modules/key-vault/main.tf:105-123`). Terraform is not a trusted Azure service, so the vault refuses those calls with a 403 unless the runner can reach it. | Hosted CI runners do not have one fixed egress address you can allow-list. | On a runner with a stable egress IP, leave this `false` and set `key_vault_network_acls_ip_rules = ["<runner IP>"]` (`modules/wordpress-site/variables.tf:136-140`). |
| `storage_network_rules_default_action = "Allow"` | `"Deny"` (`modules/wordpress-site/variables.tf:172-181`) | **Media, for every visitor.** The WordPress Blob Storage plugin points media URLs at the storage account's own blob endpoint, so browsers fetch media from Azure directly (`modules/wordpress-site/variables.tf:168-171`). Browser addresses cannot be allow-listed, so each image returns 403. | This site has no CDN in front of the blob endpoint. | Keep `"Deny"` only when the blob endpoint is fronted by a CDN custom domain, and allow-list that CDN's egress ranges with `storage_network_rules_ip_rules`. |

Neither input affects how the site itself reads secrets. The App Service subnet is always allowed through both
firewalls (`modules/wordpress-site/main.tf:363-366` and `:419-422`), so Key Vault references and media uploads
from WordPress keep working with either setting.

### The other choices

- **`cdn_provider = "direct"`** creates no CDN and no Cloudflare or Front Door resources. The Cloudflare and
  `azapi` providers are still downloaded at `terraform init`, because the module declares them
  (`modules/wordpress-site/main.tf:17-46`), but they need no configuration here.
- **`custom_domain` ends in `.azurewebsites.net`**, so the module creates no custom-hostname binding
  (`modules/wordpress-site/main.tf:942-944`) and needs no DNS record. WordPress's `WP_HOME` and `WP_SITEURL` are
  `https://<custom_domain>` (`modules/app-service/main.tf:74-75`). The app is named
  `app-<project_name>-<site_name>-np` (`modules/app-service/main.tf:10`, `:159`), so the value above is the app's
  own host name. The Verify step checks that.
- **`sku_name = "S1"`, not `B1`.** With a dedicated plan, the app-service module always creates an autoscale
  setting on the plan (`modules/app-service/main.tf:449-450`). Microsoft documents autoscale for Standard tier and
  up ([Automatic scaling, "Scale-out options"](https://learn.microsoft.com/en-us/azure/app-service/manage-automatic-scaling)).
  Whether Azure rejects that autoscale setting on a Basic plan is **UNKNOWN**: it has not been tested. S1 also
  gets a staging slot (`modules/app-service/main.tf:24`, `:331-332`). To run on B1, use a shared plan, which
  creates no autoscale setting by default; see
  [step 11 of the deployment guide](deployment-guide.md#step-11-host-several-sites-on-a-shared-plan).
- **`environment = "nonprod"`** selects the nonprod defaults:
  - MySQL `B_Standard_B2s`, 7-day backups, no geo-redundant backup (`modules/wordpress-site/main.tf:97-105`);
  - Key Vault purge protection off and 7-day soft-delete retention (`modules/wordpress-site/main.tf:113-116`), so
    a destroyed vault frees its name at once;
  - `WP_DEBUG` on (`modules/app-service/main.tf:112`).
- **`resource_provider_registrations = "legacy"`** keeps the azurerm 4.x behaviour of registering resource
  providers automatically; azurerm 5.x defaults to `none`
  ([provider docs](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs#resource_provider_registrations)).
  The examples use the same setting (`examples/basic-site/main.tf:20-23`). If your identity may not register
  providers, use `none` and register them once by hand (see Prerequisites in the deployment guide).

### Names that must be unique

Four of the names the module builds are global across all of Azure, not just your subscription.

| Resource | Name pattern | Source |
|---|---|---|
| App Service | `app-<project_name>-<site_name>-np` | `modules/app-service/main.tf:10`, `:159` |
| MySQL server | `mysql-<project_name>-<site_name>-np` | `modules/database/main.tf:36` |
| Key Vault | `kv-<site_name with its hyphens removed, then cut to 14 characters>-np<key_vault_name_suffix>` (the suffix defaults to `9`) | `modules/key-vault/main.tf:25`, `modules/wordpress-site/variables.tf:825-829` |
| Storage account | `sttr<site_name with its hyphens removed, then cut to 12 characters>np` | `modules/storage/main.tf:11` |

The Key Vault and storage names do **not** include `project_name`. A short, common `site_name` such as `blog`
is therefore likely to be taken. Choose a distinctive one.

## Steps

### Step 1: Choose the names

**Who:** operator. **STOP:** yes. Do not continue until the storage account name is free.

Pick `project_name` (2-24 characters) and `site_name` (2-22 characters)
(`modules/wordpress-site/variables.tf:4-22`). Check the storage account name, the most likely clash:

```bash
az storage account check-name --name sttrexamplewp01np --query nameAvailable
```

A clash on the other three names shows up as a "name already in use" error at apply. If that happens, change
`site_name` and run again.

### Step 2: Prepare state, the CI identity and the pipeline

**Who:** Azure administrator, then operator. **STOP:** yes. This needs permission to create role assignments.

Follow steps 1, 2 and 5 of the [deployment guide](deployment-guide.md). You need the state storage account, an
identity that CI can sign in as with OIDC, and a pipeline that plans on pull requests and applies from `main`.
For this guide, the nonprod jobs of that pipeline are enough.

### Step 3: Add the configuration

**Who:** operator. **STOP:** no.

Commit `main.tf` and `backend.hcl` from above, with your names.

### Step 4: Lock the provider versions

**Who:** operator. **STOP:** no.

```bash
terraform init -backend=false
terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64 -platform=windows_amd64
git add .terraform.lock.hcl
```

Commit the lock file. Step 3 of the [deployment guide](deployment-guide.md) explains why.

### Step 5: Open a pull request

**Who:** operator, then CI. **STOP:** no.

Open a pull request with the configuration. The pipeline's plan job runs:

```bash
terraform init -input=false -backend-config=backend.hcl
terraform plan -input=false -lock-timeout=10m
```

The job sets `ARM_USE_OIDC`, `ARM_USE_AZUREAD`, `ARM_CLIENT_ID`, `ARM_TENANT_ID` and `ARM_SUBSCRIPTION_ID`
(step 5 of the [deployment guide](deployment-guide.md#step-5-write-the-pipeline)).

### Step 6: Review the plan

**Who:** operator. **STOP:** yes. Do not merge until all four checks pass in the pull request's plan.

1. The summary reads `Plan: 33 to add, 0 to change, 0 to destroy.` That is the count for this configuration at
   v4.1.1.
2. `module.wordpress.module.key_vault.azurerm_key_vault.main` shows `default_action = "Allow"` under
   `network_acls`.
3. `module.wordpress.module.storage.azurerm_storage_account.main` shows `default_action = "Allow"` under
   `network_rules`.
4. The resource names match the ones you checked in step 1.

### Step 7: Merge and apply

**Who:** operator, then CI. **STOP:** no.

Merge the pull request. The pipeline's nonprod job plans again and applies that plan:

```bash
terraform plan -input=false -lock-timeout=10m -out=tfplan
terraform apply -input=false tfplan
```

The job applies straight after it plans, with no pause. Afterwards, read its plan summary in the job log: it must
match the one you reviewed in step 6. If it does not, something changed in between. Hold further changes and
find out what before the next apply.

### Step 8: Open the site

**Who:** operator. **STOP:** no.

Open the `wordpress_url` output in a browser. The first start of the container can take a while. If WordPress
shows its installer, complete it.

## Verify

**Who:** operator, from a shell signed in to Azure with read access to the subscription and the state.

1. The site's URL is the app's own host name:

   ```bash
   test "$(terraform output -raw wordpress_url)" = "https://$(terraform output -raw app_service_default_hostname)" && echo match
   ```

   If this does not print `match`, WordPress is pointing at the wrong host. Set `custom_domain` to the
   `app_service_default_hostname` value and apply again.
2. The health-check file answers. The module probes `/wp-includes/images/blank.gif`
   (`modules/wordpress-site/main.tf:128`):

   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' "$(terraform output -raw wordpress_url)/wp-includes/images/blank.gif"
   ```

   Expect `200`.
3. Both firewalls are open as configured:

   ```bash
   az keyvault show --name kv-examplewp01-np9 --query properties.networkAcls.defaultAction -o tsv
   az storage account show --name sttrexamplewp01np --query networkRuleSet.defaultAction -o tsv
   ```

   Expect `Allow` from both.

### How this configuration was tested

The configuration above was planned offline with `terraform test` and a mocked `azurerm` provider, on
Terraform 1.9.8, with the module fetched from the `v4.1.1` tag. The plan succeeded with 33 resources to add,
including the staging slot and its Key Vault access policy. Both network rules planned as `Allow`. Without the two
inputs they planned as `Deny`. A mocked plan proves that the configuration is valid and shows what it creates. It
does not prove that Azure accepts it: it never calls Azure.

## Rollback

**Who:** operator, then CI. **STOP:** yes. This deletes the site and its data.

1. Back up anything you want to keep: the database and the media container.
2. Run the destroy as the identity that applied, the CI identity, for example from a manually started pipeline
   job. Another identity has no access policy on the vault (`modules/key-vault/main.tf:70-101`,
   `modules/wordpress-site/main.tf:530-568`), so it cannot read the secrets during the refresh.

   ```bash
   terraform plan -destroy -input=false -out=tfplan
   ```

3. Check that the plan destroys only this site's resources: `0 to add, 0 to change, 33 to destroy`.
4. Apply it:

   ```bash
   terraform apply -input=false tfplan
   ```

The vault was created without purge protection, and the azurerm provider purges a vault on destroy by default
(`purge_soft_delete_on_destroy`,
[features block](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/features-block)).
So you can reuse the same names at once.

## Next steps

- Move to the consumer pattern, with environments and a gated production apply: [deployment guide](deployment-guide.md).
- Estimate the bill: [cost guide](cost.md).
- Put a CDN in front of the site: the README's "CDN Options" section and [`examples/basic-site`](../examples/basic-site/).
- Harden the SCM (Kudu) endpoint and publishing credentials: [`modules/app-service/README.md`](../modules/app-service/README.md).

## References

- [Terraform `azurerm` backend (Terraform 1.9)](https://developer.hashicorp.com/terraform/language/v1.9.x/backend/azurerm)
- [Dependency lock file (Terraform 1.9)](https://developer.hashicorp.com/terraform/language/v1.9.x/files/dependency-lock)
- [`terraform test` and mock providers](https://developer.hashicorp.com/terraform/language/tests/mocking)
- [AzureRM provider: resource provider registrations](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs#resource_provider_registrations)
- [Azure App Service: scale-out options](https://learn.microsoft.com/en-us/azure/app-service/manage-automatic-scaling)
- [Azure App Service: staging slots](https://learn.microsoft.com/en-us/azure/app-service/deploy-staging-slots)
