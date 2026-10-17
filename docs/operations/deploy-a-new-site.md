# Deploy a new site

## When to use

You already run this module in production (remote state, CI that plans pull requests and applies from `main`, one
root per environment) and want to add one more WordPress site. For a first deployment use
[Getting started](../getting-started.md); for the pipeline itself use the [deployment guide](../deployment-guide.md).
This runbook is the short, repeatable version of [deployment guide step 10](../deployment-guide.md#step-10-onboard-a-site).

## Prerequisites

- A working root configuration per environment, with the pipeline from deployment guide steps 1 to 5, and the module
  source pinned with `?ref=v4.3.0` (or the release you run).
- No `depends_on` on the `wordpress-site` module call, and `deployer_object_id`/`deployer_tenant_id` set if plan
  and apply run as different identities ([deployment guide steps 6 and 7](../deployment-guide.md#step-6-decide-whether-to-set-the-deployer-id-inputs)).
  Both are read from `modules/wordpress-site/main.tf`.
- Rights to change DNS for the site's domain, if the module does not manage it (see step 2).
- The inputs with no default: `project_name`, `site_name`, `environment`, `location`, `tenant_id` and
  `custom_domain` (`modules/wordpress-site/variables.tf`).

## Steps

1. **Choose names that are free.** Four names are global across Azure, and the vault and storage names do not
   contain `project_name`, so a short common `site_name` is likely to clash.

   | Resource | Name |
   | --- | --- |
   | App Service | `app-<project_name>-<site_name>-<np\|prod>` |
   | MySQL server | `mysql-<project_name>-<site_name>-<np\|prod>` |
   | Key Vault | `kv-<site_name, hyphens removed, cut to 14 characters>-<np\|prod><key_vault_name_suffix>` |
   | Storage account | `sttr<site_name, hyphens removed, cut to 12 characters><np\|prod>` |

   Sources: `modules/app-service/main.tf`, `modules/database/main.tf`, `modules/key-vault/main.tf`,
   `modules/storage/main.tf`. Check the storage name, the most likely clash:

   ```bash
   az storage account check-name --subscription <subscription-id> --name <storage-account-name> --query nameAvailable
   ```

   Expect `true`. A clash on another name shows only at apply, as "name already in use"; see
   [Getting started, step 1](../getting-started.md#step-1-choose-the-names) for how to recover.

2. **Prepare DNS.** What you create depends on `cdn_provider`:

   - `cloudflare` with `cloudflare.enabled = true`: the module creates the records and binds the domain. Give the
     pipeline a Cloudflare token first (see [Rotate secrets](rotate-secrets.md#cloudflare-api-tokens)). Leave
     `cloudflare.enable_page_rules` on for exactly one site per zone.
   - `azure_front_door`, `direct`, or `cloudflare` with `cloudflare.enabled = false`: create the TXT record
     `asuid.<subdomain>` holding the app's domain verification ID. With `direct`, also point the CNAME at the app.
     With Front Door, create the `_dnsauth` TXT record and the endpoint CNAME after the first apply.
     If the domain already serves a live site, create only the TXT record now and leave its CNAME or A record alone:
     repoint it only after the new site is verified.
   - A `custom_domain` ending in `.azurewebsites.net` needs no DNS.
   - `direct` with your own domain also needs a certificate. The module binds the host name without one, so HTTPS on
     the custom domain fails certificate validation until you bind an App Service managed or imported certificate
     yourself ([security model, TLS settings](../security-model.md#tls-settings)). Until then, verify against the app's
     default host name.

   Treat every DNS change on a live domain as its own reviewed change. The exact records, and what to do if the
   verification ID is not available before the first apply, are in
   [deployment guide step 10](../deployment-guide.md#step-10-onboard-a-site), item 2.

3. **Decide the Key Vault and storage network inputs.** Both deny public data-plane access by default. Terraform
   is not a trusted Azure service, so the first apply fails at the Key Vault secrets unless the runner can reach the
   vault: set `key_vault_network_acls_ip_rules` to the runner's egress address, or
   `key_vault_public_network_access_enabled = true`. Keep `storage_network_rules_default_action` at its default,
   `"Deny"`, unless you install a Blob offload plugin that points browsers at the blob endpoint. See
   [Troubleshooting](troubleshooting.md#key-vault-403-from-ci) and the
   [security model](../security-model.md#key-vault-and-storage-deny-public-access-by-default).

4. **Add the site and open a pull request.** Add one entry to the map your root passes to the module, or a new
   `module` block, based on `examples/multi-site/main.tf` (shared plan) or `examples/basic-site/main.tf` (dedicated
   plan). If the site joins a shared plan, set `app_service.use_shared_plan = true` and pass
   `shared_resource_group_name` ([deployment guide step 11](../deployment-guide.md#step-11-host-several-sites-on-a-shared-plan)).
   Run the formatter locally:

   ```bash
   terraform fmt -recursive -check -diff
   ```

5. **Read the nonprod plan.** CI runs the equivalent of:

   ```bash
   terraform init -input=false -backend-config=backend.hcl
   terraform plan -input=false -lock-timeout=10m -detailed-exitcode
   ```

   Exit code 2 means changes, which is expected here. The plan must add only the new site's resources. It must not
   update or replace `azurerm_key_vault_access_policy.terraform` on any existing site. If it does, look for a
   `depends_on` on the module call or a change of planning identity, and read
   [Deferred data-source reads](troubleshooting.md#a-plan-wants-to-replace-the-terraform-access-policy).

6. **Merge and apply nonprod.** With `azure_front_door`, create the `_dnsauth` TXT record and the endpoint CNAME now.
   Then verify (below) before you touch production.

7. **Repeat for production** in a second pull request, after nonprod is verified. The production job waits for
   its reviewers; read its plan with the plan-only job from
   [deployment guide Verify item 1](../deployment-guide.md#verify) if your pipeline has one.

## Verify

Run these for each environment. `curl` is the only tool needed beyond `az`.

1. The app answers. A site behind Cloudflare or Front Door answers `403` on its default host name by design; test
   through the custom domain instead. A `direct` site with a custom domain and no certificate yet cannot be tested
   over HTTPS on that domain: use `https://<app-name>.azurewebsites.net/` until you bind one.

   ```bash
   az webapp show --subscription <subscription-id> --resource-group <app-resource-group> --name <app-name> \
     --query "{state:state, host:defaultHostName}" -o table
   curl -sS -o /dev/null -w '%{http_code}\n' "https://<custom-domain>/wp-includes/images/blank.gif"
   ```

   Expect `Running` and `200`. The health-check file the module probes by default is
   `/wp-includes/images/blank.gif` (`modules/wordpress-site/main.tf`, the `app_service.health_check_path` default).

2. The installer is closed on production and on the staging slot, if there is one
   ([Getting started, Verify item 4](../getting-started.md#verify)).
3. A re-plan reports no changes.
4. Alerts are routed ([Alerting](alerting.md)) and a backup is scheduled if you use one
   ([Backup and restore](backup-and-restore.md)).

## Rollback

- **Before the first successful apply:** close the pull request.
- **After an apply:** remove the map entry. That destroys the site's database, storage, vault and the web app's
  files, so [back up first](backup-and-restore.md) and follow
  [deployment guide step 12](../deployment-guide.md#step-12-remove-a-site) (locks, DNS, the production plan,
  platform-created alert rules). Removing a site is not undoable.
- A site that applied but misbehaves is better stopped than removed: `az webapp stop --subscription <subscription-id>
  --resource-group <app-resource-group> --name <app-name>` (add `--slot staging` for the slot), then fix and
  `az webapp start`.

## Sources

`modules/wordpress-site/variables.tf`, `modules/wordpress-site/main.tf`, `examples/basic-site/main.tf`,
`examples/multi-site/main.tf`, [deployment guide](../deployment-guide.md), [Getting started](../getting-started.md).
