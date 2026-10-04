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

- **Two Azure subscriptions:**
  - a nonprod subscription, where the CI identity gets **Contributor** at subscription scope. The module creates
    its own resource group (`modules/wordpress-site/main.tf:185-188`), so a role scoped to one resource group is
    not enough.
  - a management subscription that holds the state account and the CI identity. There, the identity gets only a
    data role on its own state container. The [deployment guide's prerequisites](deployment-guide.md#prerequisites)
    explain why these must not sit in the subscription the identity deploys to.
- **An Azure administrator** with Owner, or Contributor plus User Access Administrator, on both subscriptions. They
  create the state account, the identity and the role assignments. Contributor alone cannot assign roles.
- **Remote state and an OIDC identity for CI.** Set these up with steps 1 and 2 of the
  [deployment guide](deployment-guide.md). Only the nonprod identity and the `tfstate-nonprod` container are needed
  here.
- **Admin rights on the GitHub repository** that holds the configuration, to create the environment the pipeline
  uses.
- **The Azure CLI**, signed in, for step 1 and Verify.
- **Terraform 1.6.0 or later** (`modules/wordpress-site/main.tf:15`). The module's own CI uses 1.9.8, and the
  configuration below was tested on 1.9.8.
- **Outbound access from the runner:**
  - `github.com` and `release-assets.githubusercontent.com`, for the module source and for the `azapi` and
    `cloudflare` provider downloads (the registry sends those to GitHub release downloads, which redirect to
    that second host);
  - `registry.terraform.io` and `releases.hashicorp.com` (the HashiCorp providers);
  - `login.microsoftonline.com`, `management.azure.com`, `<state account>.blob.core.windows.net` and
    `<vault name>.vault.azure.net`.

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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
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

# The bootstrap password for the WordPress administrator. The container passes it to wp-cli
# unquoted, so it must be one shell word: no special characters.
resource "random_password" "wp_admin" {
  length  = 40
  special = false
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

    # Makes the container install WordPress itself on first start: see "The administrator account".
    # Change the user (one word) and the email.
    extra_app_settings = {
      WORDPRESS_ADMIN_USER     = "wpadmin"
      WORDPRESS_ADMIN_EMAIL    = "admin@example.com"
      WORDPRESS_ADMIN_PASSWORD = random_password.wp_admin.result
    }
  }
}

output "wordpress_url" {
  value = module.wordpress.wordpress_url
}

output "app_service_default_hostname" {
  value = module.wordpress.app_service_default_hostname
}

output "wordpress_admin_password" {
  value     = random_password.wp_admin.result
  sensitive = true
}
```

`backend.hcl` (no secrets in it, so you can commit it):

```hcl
resource_group_name  = "rg-tfstate-example"
storage_account_name = "sttfstateexample"
container_name       = "tfstate-nonprod"
key                  = "wordpress.tfstate"
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
| `storage_network_rules_default_action = "Allow"` | `"Deny"` (`modules/wordpress-site/variables.tf:172-181`) | **Media that browsers fetch from the blob endpoint.** A storage plugin that rewrites media URLs to the account's own blob endpoint makes browsers fetch media from Azure directly (`modules/wordpress-site/variables.tf:168-171`). Browser addresses cannot be allow-listed, so with `Deny` each image returns 403. Nothing in this configuration does that by default: the module does not install the plugin, so uploads stay on the app's `/home` storage. | It removes the firewall gate for browsers that fetch from the blob endpoint. It is only half of the fix; see the paragraph below the table. | Keep `"Deny"`, the default, while uploads stay on `/home`. Do not rely on a CDN custom domain and `storage_network_rules_ip_rules` for media: see [Media](architecture.md#media). |

Neither input affects how the site itself reads secrets. The App Service subnet is always allowed through both
firewalls (`modules/wordpress-site/main.tf:363-366` and `:419-422`), so Key Vault references and media uploads
from WordPress keep working with either setting.

The storage firewall is one of two gates on media that browsers fetch from the blob endpoint, and `Allow` removes
only the first. The account also disallows anonymous blob access (`modules/storage/main.tf:28`) and the uploads
container is private (`modules/storage/main.tf:91`). Azure therefore rejects every anonymous read, and neither
setting is an input. The Microsoft Azure Storage for WordPress plugin (4.5.2) writes unsigned URLs, so media does
not load from the blob endpoint with it. Whether another plugin serves SAS-signed URLs is UNKNOWN; see
[Media](architecture.md#media) in the architecture overview and the
[security model](security-model.md#key-vault-and-storage-deny-public-access-by-default).

### The administrator account

This configuration sits on a public `*.azurewebsites.net` name from the moment the apply finishes. A fresh
WordPress shows its installer to whoever reaches it first, and whoever completes the installer becomes the
administrator and can run code in the app. The app's environment holds the resolved database password and storage
key, and its identity can read the vault's secrets (`modules/wordpress-site/main.tf:531-545`). So the
configuration removes that window instead of asking you to win a race.

The `WORDPRESS_ADMIN_USER`, `WORDPRESS_ADMIN_EMAIL` and `WORDPRESS_ADMIN_PASSWORD` app settings make the container
run `wp core install` with those values on its first start, behind a static holding page and before it serves
WordPress, so `/wp-admin/install.php` is never public. The staging slot inherits the settings
(`modules/app-service/main.tf:436`) and shares the database. The container does not read a title setting: the
site title starts as "WordPress on Azure".

The password is generated by Terraform and kept in state and in the app's settings, so change it after you sign in
(step 8).

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
az storage account check-name --subscription <nonprod-subscription-id> --name sttrexamplewp01np --query nameAvailable
```

Check the vault name as well. For example, for `site_name = "examplewp01"`:

```bash
az keyvault check-name --subscription <nonprod-subscription-id> --name kv-examplewp01-np9 --query nameAvailable
```

A clash on the other names shows up as a "name already in use" error at apply. If that happens, change `site_name`
and run again. Expect that run to stop while it deletes the first resource group: Application Insights is created
before the vault and the app (`modules/wordpress-site/main.tf:273-282`), so that group already holds the two
resources Azure created with it, and changing `site_name` replaces the group. When the run stops on
`the Resource Group still contains Resources`, delete the two resources it lists, as in Rollback, then run again.

### Step 2: Prepare state, the CI identity and the pipeline

**Who:** Azure administrator, then operator. **STOP:** yes. This needs permission to create role assignments.

Follow steps 1, 2, 4 and 5 of the [deployment guide](deployment-guide.md). You need the state storage account, an
identity that CI can sign in as with OIDC, and a pipeline that plans on pull requests and applies from `main`.
For this guide, the nonprod identity and the nonprod jobs of that pipeline are enough.

### Step 3: Add the configuration

**Who:** operator. **STOP:** no.

Commit `main.tf` and `backend.hcl` from above, with your names, in `infra/nonprod/`, the directory the pipeline's
nonprod jobs run in (step 4 of the
[deployment guide](deployment-guide.md#step-4-lay-out-one-root-configuration-per-environment)). Run step 4 below in
that directory.

### Step 4: Lock the provider versions

**Who:** operator. **STOP:** no.

```bash
terraform init -backend=false
terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64 -platform=windows_amd64
git add .terraform.lock.hcl
```

Commit the lock file, in `infra/nonprod/` too. Step 3 of the [deployment guide](deployment-guide.md) explains why.

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

1. The summary reads `Plan: 34 to add, 0 to change, 0 to destroy.` That is the count for this configuration at
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
terraform apply -input=false -lock-timeout=10m tfplan
```

The job applies straight after it plans, with no pause. Afterwards, read its plan summary in the job log: it must
match the one you reviewed in step 6. If it does not, something changed in between. Hold further changes and
find out what before the next apply.

### Step 8: Sign in and check the installer is closed

**Who:** operator. **STOP:** yes, if the installer is open: stopping the app changes Azure.

Sign in at `<wordpress_url>/wp-admin` as the user you chose, with the password from
`terraform output -raw wordpress_admin_password`. Run that command as described in Verify item 1. The first start
of the container can take a while.

Change the password at once: the bootstrap value stays in state and in the app's settings.

If either `https://app-<project_name>-<site_name>-np.azurewebsites.net` or
`https://app-<project_name>-<site_name>-np-staging.azurewebsites.net` shows the WordPress installer instead, the
headless install did not run. Anyone who reaches it can finish it, become administrator, run code in the app, and
read its database password, storage key and Key Vault secrets. Stop both now:

```bash
az webapp stop --subscription <nonprod-subscription-id> -g rg-<project_name>-<site_name>-np -n app-<project_name>-<site_name>-np
az webapp stop --subscription <nonprod-subscription-id> -g rg-<project_name>-<site_name>-np -n app-<project_name>-<site_name>-np --slot staging
```

Without `--slot`, only production stops. Fix the settings, apply, then run `az webapp start` with the same two
forms.

## Verify

**Who:** operator, from a shell signed in to Azure with Reader on the nonprod subscription. No access to the state
is needed, except for the optional `terraform output` in item 1.

1. The site's URL is the app's own host name. The apply job prints `wordpress_url` and
   `app_service_default_hostname` under `Outputs:` at the end of its log. `wordpress_url` must be `https://`
   followed by `app_service_default_hostname`. Or read the host name from Azure:

   ```bash
   az webapp show --subscription <nonprod-subscription-id> --resource-group rg-example-examplewp01-np --name app-example-examplewp01-np --query defaultHostName -o tsv
   ```

   Expect your `custom_domain` value, `app-example-examplewp01-np.azurewebsites.net`. If the command errors or
   prints nothing, this check proves nothing: fix the sign-in or the subscription first. Only if it prints a
   different host name, set `custom_domain` to that value and apply again.

   To use `terraform output` locally instead, run `terraform init -input=false -backend-config=backend.hcl` first.
   It replaces the `-backend=false` init from step 4. Run it as an identity that holds Storage Blob Data Reader on
   the `tfstate-nonprod` container, which is enough for these read-only commands once state exists. Terraform
   1.9's documentation names Storage Blob Data Owner for read-write use. The state holds the database password,
   the storage account key, the Application Insights connection string and the administrator password, so grant
   that role only to people allowed to read those secrets. If a `terraform output` command errors, the comparison
   proves nothing.
2. The health-check file answers. The module probes `/wp-includes/images/blank.gif`
   (`modules/wordpress-site/main.tf:128`):

   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' "https://app-example-examplewp01-np.azurewebsites.net/wp-includes/images/blank.gif"
   ```

   Expect `200`. This file answers `200` on a site that has no administrator yet, so it does not prove the
   installer is closed; item 4 does.
3. Both firewalls are open as configured:

   ```bash
   az keyvault show --subscription <nonprod-subscription-id> --name kv-examplewp01-np9 --query properties.networkAcls.defaultAction -o tsv
   az storage account show --subscription <nonprod-subscription-id> --name sttrexamplewp01np --query networkRuleSet.defaultAction -o tsv
   ```

   Expect `Allow` from both.
4. The installer is closed on both hosts. Fetch the body, not just the status:

   ```bash
   for h in app-example-examplewp01-np app-example-examplewp01-np-staging; do
     body=$(curl -sSL --fail "https://$h.azurewebsites.net/") || { echo "$h: UNREACHABLE, check proves nothing"; continue; }
     printf '%s' "$body" | grep -q 'id="setup"' && echo "$h: INSTALLER OPEN"
   done
   ```

   Expect no output. An `UNREACHABLE` line means the check proved nothing for that host.
5. Exactly one administrator, yours. In `/wp-admin`, open Users. An install someone else completed looks the same
   over HTTP. If you see any other administrator, treat the app as compromised: destroy and redeploy it (see
   Rollback).

### How this configuration was tested

The configuration above was planned offline with `terraform test` and a mocked `azurerm` provider, on
Terraform 1.9.8, with the module fetched from the `v4.1.1` tag. The plan succeeded with 34 resources to add,
including the staging slot, its Key Vault access policy and the administrator password. Both network rules planned as `Allow`. Without the two
inputs they planned as `Deny`. A mocked plan proves that the configuration is valid and shows what it creates. It
does not prove that Azure accepts it: it never calls Azure.

## Rollback

**Who:** operator, then CI. **STOP:** yes, at the merge in item 4. This deletes the site and its data.

1. Back up anything you want to keep, from inside the network, and check each copy before you go on. The backup
   only reads data. Your workstation cannot export the database: the MySQL server has no public endpoint, and its
   subnet admits port 3306 only from the App Service subnet (`modules/database/main.tf:64-66`,
   `modules/networking/main.tf:137-171`). Work in the app's SSH console (`az webapp ssh`, or the SCM site's SSH
   option). Export the database with
   `mkdir -p /home/backups && wp db export /home/backups/wordpress.sql --path=/home/site/wwwroot --allow-root`,
   archive the site files with `tar -czf /home/backups/wwwroot.tar.gz -C /home/site wwwroot`, and download both
   through the SCM (Kudu) site. Never write the dump under `/home/site/wwwroot`, the public web root. Uploads stay in
   `/home` unless you installed a storage plugin, so copy the blob account's containers too if you did. Opening the
   SCM or storage firewall to your address first is an Azure change. The
   [deployment guide's step 12](deployment-guide.md#step-12-remove-a-site) has the full procedure.
2. In a pull request, delete the `module "wordpress"` block, the `random_password` resource and the three `output`
   blocks from `main.tf`. Keep the provider block, `backend.hcl` and `.terraform.lock.hcl`. The plan job signs in
   as the nonprod identity, which is the identity that applied. No other identity has an access policy on the vault
   (`modules/key-vault/main.tf:70-101`, `modules/wordpress-site/main.tf:530-568`), so no other identity could read
   the secrets during the refresh.
3. The pull request's plan must read `Plan: 0 to add, 0 to change, 34 to destroy.`, and every resource it lists
   must be `random_password.wp_admin` or start with `module.wordpress.`. Do not merge until it does.
4. Merge. The `apply-nonprod` job plans again and applies that plan with no pause. Afterwards, read its plan
   summary in the job log: it must match item 3.
5. **Who:** operator. **STOP:** yes. Expect this apply to fail at its last step, after about ten minutes of retries, with
   `deleting Resource Group "rg-<project_name>-<site_name>-np": the Resource Group still contains Resources`.
   Everything else has been deleted by then.

   When Azure created Application Insights, it also created two resources in the same resource group:

   - a `Failure Anomalies - appi-<project_name>-<site_name>-np` smart detector alert rule;
   - an `Application Insights Smart Detection` action group.

   Neither is in Terraform state, and deleting Application Insights does not delete them. Delete the resources the
   error lists:

   ```bash
   az resource delete --subscription <nonprod-subscription-id> --ids "<rule resource ID from the error>"
   az monitor action-group delete --subscription <nonprod-subscription-id> -g rg-<project_name>-<site_name>-np -n "Application Insights Smart Detection"
   ```

   Then run the pipeline again: it plans and applies the same destroy. That plan reads
   `0 to add, 0 to change, 1 to destroy` (the resource group).

   Do not delete these two resources before the destroy: while Application Insights exists, Azure re-creates the
   rule within minutes.

   Alternative for this nonprod-only configuration: in the pull request of item 2, add
   `resource_group { prevent_deletion_if_contains_resources = false }` to the provider's `features` block. The
   provider then deletes the group with everything in it, including resources Terraform does not manage.

Do not run `terraform plan -destroy` while `main.tf` still declares the site. The pipeline has no job for it, and
the next push to `main` would plan `34 to add` and re-create the site.

If you want a one-off destroy job instead, it must be a `workflow_dispatch` workflow already on the default
branch. Its job sets both `environment: nonprod` and `concurrency: nonprod`, and the same `ARM_*` variables as
`apply-nonprod`. It runs `terraform init -input=false -backend-config=backend.hcl`, then
`terraform plan -destroy -input=false -lock-timeout=10m -out=tfplan`, then a check that the summary reads
`Plan: 0 to add, 0 to change, 34 to destroy.` (exit on mismatch), then
`terraform apply -input=false -lock-timeout=10m tfplan`. Dispatching it is the STOP. The module block must also be
removed from `main` in the very next push, or `apply-nonprod` re-creates the site. Without
`environment: nonprod`, the job's OIDC subject names the branch it was started on, which the identity does not
trust, so `terraform init` fails to sign in.

The vault was created without purge protection, and the azurerm provider purges a vault on destroy by default
(`purge_soft_delete_on_destroy`,
[features block](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/features-block)).
Once the destroy has finished, including the resource group, you can reuse the same names at once.

## Next steps

- See how the parts fit together, with diagrams: [architecture overview](architecture.md).
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
