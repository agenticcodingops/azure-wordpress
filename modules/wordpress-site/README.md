# WordPress Site Module

Complete WordPress deployment composition module that orchestrates all sub-modules.

## Overview

This module creates a complete WordPress site deployment including:
- Resource Group
- Virtual Network with subnets
- MySQL Flexible Server with private endpoint
- Azure Blob Storage for media
- Key Vault for secrets management
- App Service with managed identity
- Optional monitoring and CDN

## Upgrading to v4.1.0

Additive. A consumer that sets no new input plans **no changes** against v4.0.2 state, apart from any
exception listed below. Pin `?ref=v4.1.0` to upgrade.

Everything new in this release is off until you set it: availability tests, the four `monitoring.alerts`
families, the Key Vault, blob and staging-slot diagnostic settings, the MySQL slow query log, and `lock` on
this module and on shared-infrastructure. All of them use the azurerm provider the module already requires.

- **The Cloudflare zone lookup is no longer deferred.** This module's `module "cloudflare"` dropped its
  `depends_on = [module.app_service]`. Through v4.0.2 any pending app-service change, in this site or
  (under `for_each`) a sibling, deferred `data.cloudflare_zones` to apply time. Every `cloudflare_ruleset`
  and zone setting then planned an unknown `zone_id`, and a ruleset's `zone_id` forces replacement. DNS
  records and page rules were shielded by `ignore_changes = [zone_id]`; rulesets and zone settings were not.
  Ordering is unchanged: the DNS records still wait for the web app through their input references, and the
  TXT record, the DNS-propagation wait and the hostname binding still run in that order. A `depends_on` on
  your own call to this module would defer the lookup again, so don't add one.
- **The one exception: the container image default is now the floating `"8.3"`** (it was `"8.4"`). If you never
  set `wordpress_version`, the plan updates `docker_image_name` in place on the app, and on S*/P* plans on the
  staging slot: `appsvc/wordpress-debian-php:8.4` becomes `:8.3`. Floating `"8.4"` does not exist on the registry
  (measured 2026-09-27: `manifests/8.4` returns 404, `manifests/8.3` returns 200; the 8.4 series is published only as
  dated tags), so the old default cannot survive a restart or a move to a new instance. To keep your current value, set `wordpress_version` explicitly.
  A dated tag such as `8.3_20260922.3.tuxprod` pins the image exactly, but disables automatic platform image updates.
  As with any image change, a green apply does not prove the container restarted: check `x-powered-by` and restart
  the app if the old PHP is still serving.
- **New, optional: `deployer_object_id` and `deployer_tenant_id`.** Unset (the default), nothing changes: the
  module keeps reading the deploying principal itself. Set both only when the principal that runs `apply` is not
  the one this module would read at plan time (for example, a separate plan identity), or when you need your own
  `depends_on` on this module. Pass lowercase values that are known at plan time, from a root-level
  `azurerm_client_config` with no `depends_on`. `object_id` and `tenant_id` on `azurerm_key_vault_access_policy`
  force replacement, so a value that differs from the principal that created the existing Terraform policy
  replaces it, and revokes the old principal's access: treat that as a planned identity cutover, and grant the new
  principal access first. The now-unused read inside the module may still print "will be read during apply".
- **New, optional: `database.mysql_version`** (and `mysql_version` on the database module). The default stays
  `8.0.21`, so leaving it unset changes nothing. Setting `"8.4"` on an existing server is an irreversible
  major-version upgrade. Plan and rehearse it first, and dry-run to see whether your azurerm version changes the
  server in place or replaces it. The upgrade itself is planned in `agenticcodingops/trackroutinely#104` (WP-43);
  this input only makes it possible. MySQL 8.0 leaves standard support on 2027-01-31.
- **New, optional: `app_service_storage_plugin_app_settings_enabled`** (and `storage_plugin_app_settings_enabled`
  on the app-service module). The default `true` keeps the three `MICROSOFT_AZURE_*` app settings exactly as before.
  The container image never reads them: only the Microsoft Azure Storage for WordPress plugin does, as
  `wp-config.php` constants. So unless you run that plugin they are inert, and `false` removes them from the app
  and its staging slot, taking the storage account key out of the app's environment. Setting `false` updates the app
  settings in place. The `storage-key` Key Vault secret is unchanged.
- **Deprecated: `plan_density_limit`.** Nothing reads it, so it never limited the number of sites per plan. It
  stays, with its validation, so configurations that set it still plan. It will be removed in the next major
  release, so remove it from your configuration.
- **New, optional: `availability_tests` and `extra_action_group_ids`; new outputs `action_group_id` and
  `availability_test_ids`.** Unset, nothing changes. `availability_tests` creates a standard web test and an
  N-of-M-locations metric alert per entry (see [Availability tests](#availability-tests)); it needs
  `alert_recipients` or `extra_action_group_ids`, or the plan fails. `extra_action_group_ids` adds action groups
  to every alert this module creates, the three baseline alerts included, as extra `action` blocks beside the
  site group's. With no `alert_recipients`, setting it also creates the three baseline alerts, routed to those
  groups only. `action_group_id` is null when `alert_recipients` is empty. Microsoft retires classic URL ping
  tests on 2026-09-30; this module never created any.
- **New, optional: four alert families under `monitoring.alerts`**: `mysql`, `http_5xx_rate`, `health_check` and
  `resource_health`, each `enabled = false` by default (see [Alerting](#alerting)). Unset, nothing changes.
  Enabling one needs `alert_recipients` or `extra_action_group_ids`, or the plan fails. `db_failure_threshold`,
  declared but never read before, is now the MySQL `aborted_connections` threshold, and only when
  `mysql.enabled` is true. Azure also creates a "Failure Anomalies" rule next to every Application Insights
  component, outside Terraform; see [Failure Anomalies](#failure-anomalies-platform-created).
- **New, optional: `database.slow_query_log_enabled` and `database.long_query_time`** (and `slow_query_log_enabled`
  and `long_query_time` on the database module). Off by default, so nothing changes. When on, the module sets
  the `slow_query_log` and `long_query_time` server parameters (2 seconds unless you set it), and the
  `MySqlSlowLogs` category the MySQL diagnostic setting has always enabled finally carries rows, in
  `AzureDiagnostics`. Ingestion is billed. Both parameters are dynamic, so the server does not restart. Audit
  logging is not offered, and `MySqlAuditLogs` stays enabled but empty. See
  [MySQL slow query log](#mysql-slow-query-log).
- **New, optional: `key_vault_diagnostic_settings`, `storage_blob_diagnostic_settings` and
  `staging_slot_diagnostic_settings`.** Empty by default, so nothing changes. Each takes a map in the Azure
  Verified Modules `diagnostic_settings` shape and creates one diagnostic setting per entry, sent to the site
  workspace unless you choose another destination. The staging-slot input applies only on S* and P* SKUs. See
  [Diagnostic settings](#diagnostic-settings) for the defaults and for where the mapping differs from AVM.
- **New, optional: `lock`** (and `lock` on the shared-infrastructure module), in the Azure Verified Modules lock
  shape; only `kind = "CanNotDelete"` is accepted. Unset, nothing changes. `enable_resource_lock` still works
  and plans no change; `lock = { kind = "CanNotDelete" }` is its equivalent, and switching between them plans
  no change. Do not set both. The permission creating a lock needs is `Microsoft.Authorization/locks/*`
  (Owner or User Access Administrator; Contributor lacks it). Read [Resource locks](#resource-locks) first: while
  the lock exists, every removal or replacement in the group fails at apply, including removing a web test,
  an alert or a diagnostic setting added by this release, or turning an alert family off.

## Upgrading to v4.0.2

A bug fix. Against v4.0.1 state it plans **no changes**: the only difference is a new read of the
deploying principal. Upgrade before your next site addition or removal, tag change or storage change.

Through v4.0.1 the Key Vault module read the deploying principal (`azurerm_client_config`) itself.
That module is called with a module-level `depends_on`, so the read was deferred to apply time
whenever any `depends_on` target (networking, storage or App Insights) had a pending change. Under
`for_each` a change to *any* instance counts. Adding or removing a sibling site, a tags change, or any
storage change (with `cdn_provider = "cloudflare"`, that includes a change to Cloudflare's published
IPv4 ranges) therefore made every existing site's `azurerm_key_vault_access_policy.terraform` show
`object_id` and `tenant_id` as `(known after apply)`, and planned its replacement. On Azure that
replacement is create-then-destroy, the create is refused because the vault already holds a policy
for that object ID, and a retry plans the same replacement again. v4.0.2 reads the principal in this
module, outside that `depends_on`, and passes it in.

**Do not put `depends_on` on your own call to this module.** It defers every data source inside the
module, the new read included, so the replacement comes back whenever one of your `depends_on`
targets has a pending change. Express ordering through input references instead.

**If you gate plans:** `module.key_vault.data.azurerm_client_config.current will be read during apply`
can still appear. It is harmless, because that read is now only the standalone fallback and its value
is unused here. Gate on the policy itself: `azurerm_key_vault_access_policy.terraform` must be neither
updated nor replaced, and its `object_id` must stay known.

## Upgrading to v3.1.0

Additive. Every new input defaults to the azurerm provider's own default, so **the SCM and
publishing-credential controls produce no plan diff** if you set nothing.

One change is not zero-diff, and it is the only one: two app settings are renamed and their values
corrected. `PHP_MAX_EXECUTION_TIME` and `PHP_MAX_INPUT_VARS` become `MAX_EXECUTION_TIME` and
`MAX_INPUT_VARS`, because the Microsoft container reads those names **without** the `PHP_` prefix —
the prefixed forms were inert and never did anything. The values move to the container's documented
defaults (`120` and `10000`); the old `2000` for input vars was 80% below the real default and would
have become a live regression had the names simply been corrected. **Runtime behaviour is unchanged**
— `max_execution_time` was and stays 120, `max_input_vars` was and stays 10000. The cost is one
`app_settings` diff and an app restart on the site and its staging slot.

`PHP_MEMORY_LIMIT` is the correct name and *is* live. It stays at `256M` against a 512M container
default — deliberate, because one B1/S1 plan (1.75 GB) carries several sites plus staging slots and
512M per PHP worker widens the OOM blast radius. Override it via `app_service.extra_app_settings` on
a larger plan.

### Hardening the SCM/Kudu endpoint

The SCM endpoint (`<app>.scm.azurewebsites.net`, plus a separate one for the staging slot) is a
different gate from the `ip_restriction` rules `cdn_provider` drives, and azurerm defaults it to
`Allow`. Kudu offers a shell and read/write over the persisted `/home`, so a site restricted to
Cloudflare still had an internet-reachable Kudu before v3.1.0.

```hcl
module "wordpress" {
  source = "github.com/agenticcodingops/azure-wordpress//modules/wordpress-site?ref=v4.1.0"

  # ... existing configuration ...

  app_service_scm_ip_restrictions = [
    { ip_address = "203.0.113.10/32", name = "OperatorHome" },
  ]
  app_service_scm_ip_restriction_default_action = "Deny"

  app_service_ftp_publish_basic_authentication_enabled       = false
  app_service_webdeploy_publish_basic_authentication_enabled = false
}
```

**Read [modules/app-service/README.md](../app-service/README.md#scmkudu-network-posture) before
adopting `Deny`.** In short: the network gate and the authentication gate are independent and both
must pass, so `Deny` without an allow-list entry covering you costs the Kudu SSH console — Azure's
documented route for WP-CLI, and the only way to run the manual `wp core update --major` the
Microsoft container requires. `scm_use_main_ip_restriction` is deliberately not exposed for the same
reason. Terraform itself is unaffected either way; it uses the ARM control plane, not Kudu.

Disabling basic auth keeps `az webapp ssh` (Azure CLI ≥ 2.48.1) and the Entra-authenticated Kudu
browser UI, and breaks FTP, local Git, and build-service deploys. Kudu UI access additionally needs
the `Microsoft.Web/sites/publish/Action` RBAC operation — Reader is not enough.

Set **both** basic-auth flags, not just the WebDeploy one. ARM models the FTP and SCM publishing
policies as independent resources, so disabling WebDeploy alone leaves the FTP policy still reporting
`allow = true` even though FTP/S publishing has stopped working.

## ⚠️ Upgrading to v3.0.0 — read before you apply

v3.0.0 makes Key Vault purge protection and soft-delete retention environment-aware.

**Production consumers who set neither new variable see no change at all** — the resolved
values are still `true` and `90`, exactly what the module hardcoded before.

**Nonprod deployments that leave both new inputs unset get a destroy-and-recreate of the
Key Vault.** The new defaults are `purge_protection_enabled = false` and
`soft_delete_retention_days = 7`, and neither can be reached in place on an existing vault:
Azure permits *enabling* purge protection but never disabling it, and the retention window
"can only be configured one time and cannot be updated". Terraform's only route to the new
values is to replace the vault.

Note the asymmetry — going the other way is free. Turning purge protection **on** for a
nonprod vault is an in-place update and needs no rebuild or suffix change.

### If you do nothing, the apply fails

Terraform destroys before it creates. The old vault soft-deletes still holding its name,
and because the azurerm provider's `recover_soft_deleted_key_vaults` feature defaults to
`true`, the create step then *recovers that old vault* rather than making a new one — with
purge protection still on, which the new configuration then tries to disable. Azure refuses.

Pick one before upgrading:

```hcl
# A. Keep pre-v3.0.0 behaviour exactly. No replacement, no plan diff.
key_vault_purge_protection_enabled   = true
key_vault_soft_delete_retention_days = 90

# B. Adopt the new nonprod defaults, and give the new vault a free name in the same apply.
key_vault_name_suffix = "12"   # any value not already soft-deleted
```

Under option B the replacement vault is repopulated in the same apply, and no secret value
is lost. `random_password.db` declares no `keepers`, so the existing database password is
preserved and simply re-written into the new vault — **it is not rotated**, and the copy
inside the soft-deleted vault stays valid until that vault is purged. `storage-key` and
`appinsights-connection` are re-read from the live Storage and App Insights resources,
which are not touched. Anything you pass through `extra_secrets` is re-uploaded from your
own configuration. The App Service's `@Microsoft.KeyVault(...)` references are rewritten to
the new vault automatically.

Note the 24-character vault-name limit — `kv-{site≤14}-{env}{suffix}` — when choosing a suffix.

### Why the default changed

A purge-protected vault that is soft-deleted locks its name for the full retention period
against **everyone**; `az keyvault purge` returns `MethodNotAllowed` even for a
subscription Owner. On an environment that is deliberately destroyed and rebuilt, that
turns every cycle into a code change. Turning purge protection off is what makes the name
immediately reusable — the provider's `purge_soft_delete_on_destroy` (default `true`) then
purges cleanly on destroy. The retention value is a secondary control.

Production keeps purge protection precisely because that irreversibility is the point.

## ⚠️ Upgrading to v2.0.0 — read before you apply

v2.0.0 changes four defaults in ways that **will take a working site down** if you upgrade
without setting them. All four are opt-out; none require a code change.

### 1. Key Vault denies public access → Terraform gets 403

`network_acls.default_action` now defaults to `Deny`. Terraform is **not** a trusted Azure
service, so its data-plane calls that create secrets are refused. GitHub-hosted runners have
a large, rotating egress range that cannot practically be allow-listed.

```hcl
# Deploying from hosted CI (GitHub Actions, Azure DevOps hosted agents):
key_vault_public_network_access_enabled = true

# Or, with a self-hosted runner on a stable IP or inside the VNet:
key_vault_network_acls_ip_rules                   = ["203.0.113.10"]
key_vault_network_acls_virtual_network_subnet_ids = [azurerm_subnet.runner.id]
```

The site's own App Service subnet is allow-listed automatically, so `@Microsoft.KeyVault(...)`
references keep resolving either way. This only affects the deploying principal.

### 2. Storage denies public access → media 403s for every visitor

`network_rules.default_action` now defaults to `Deny`. This is the easiest one to under-read:
the WordPress Blob Storage plugin rewrites media URLs to the storage account's **own** blob
endpoint, so **end users' browsers fetch media directly from Azure** — from arbitrary
consumer IPs that can never be allow-listed. Every image on the site returns 403.

```hcl
# Media served straight from the blob endpoint (the default plugin behaviour):
storage_network_rules_default_action = "Allow"
```

Keep `Deny` only if the blob endpoint is fronted by a CDN custom domain, in which case
allow-list the CDN's egress ranges via `storage_network_rules_ip_rules`. When
`cdn_provider = "cloudflare"`, Cloudflare's live IPv4 ranges are added automatically — but
that covers origin pulls only, not direct browser fetches.

### 3. `database.geo_redundant_backup` now resolves `true` in production

Previously this was always `false` regardless of environment. If you never set it explicitly,
production now requests geo-redundant backup, and there are three ways that bites:

- **Not all regions have a geo-backup target.** Sweden Central reports
  `supportedGeoBackupRegions: []`, so the apply fails outright.
- **Unsupported on the Burstable tier** (`B_*` SKUs) entirely.
- **It is `ForceNew`.** Azure can only choose geo-redundancy at creation, so changing it on
  an existing server plans a **destroy and recreate**, and `modules/database` sets
  `prevent_destroy = false`.

```hcl
database = {
  geo_redundant_backup = false   # keep pre-v2.0.0 behaviour
}
```

Check your region first: `az mysql flexible-server list-skus -l <region> --query "[].supportedGeoBackupRegions"`.

### 4. `database.sku_name` now resolves `B_Standard_B2s` in nonprod

Previously every environment got `GP_Standard_D2ds_v4`. Nonprod now gets Burstable — a
**downgrade on upgrade** for anyone relying on the old accidental behaviour, and a compute
tier change that forces a restart. Pin it if you were depending on General Purpose:

```hcl
database = {
  sku_name = "GP_Standard_D2ds_v4"
}
```

### Everything else

`backup_retention_days` (production 7 → 30), `monitoring.retention_days` (production 30 → 90)
and `app_service.health_check_path` (`/` → `/wp-includes/images/blank.gif`) also become
environment-aware. All are online, non-destructive changes.

## Availability tests

`availability_tests` creates Application Insights **standard** availability tests, one per map entry, each
with one metric alert that fires when `failed_location_count` or more locations fail in the same window.
Empty (the default) creates nothing. Classic URL ping tests are never created: Microsoft retires them on
2026-09-30, and a standard test has no alert rule of its own, so the module always creates one.

```hcl
module "wordpress" {
  # ... existing configuration ...

  alert_recipients = ["ops@example.com"]

  availability_tests = {
    home = {}                                   # https://<custom_domain>/, 5 locations, every 300 s
    login = {
      path                        = "/wp-login.php"
      frequency                   = 900
      content_match               = "wp-submit"  # the test passes only if this text is found
      ssl_cert_remaining_lifetime = 14           # fail 14 days before the certificate expires
    }
  }
}
```

**An alert needs a route.** Set `alert_recipients` (the site action group), `extra_action_group_ids`, or
both; otherwise the plan fails. `extra_action_group_ids` reaches every alert this module creates,
including the three baseline alerts. With no `alert_recipients`, setting it also creates those three
alerts, routed to the extra groups only.

**Defaults, and why:**

- `url` defaults to `https://<custom_domain><path>`: the public site, through your CDN.
- Five locations (`emea-ru-msa-edge`, `emea-se-sto-edge`, `emea-nl-ams-azr`, `emea-gb-db3-azr`,
  `emea-fr-pra-edge`), Microsoft's recommended minimum. `geo_locations` accepts 1-16 IDs from
  [Microsoft's public list](https://learn.microsoft.com/azure/azure-monitor/app/availability#location-population-tags);
  the provider does not check them, so the module does.
- `failed_location_count` defaults to locations minus 2, at least 1, as Microsoft recommends.
- The alert evaluates every minute over the smallest window that holds one test interval: `PT5M` for a
  300 s test, `PT15M` for 600 s and 900 s (Azure has no 10-minute window). A 900 s test therefore gives
  about one result per location per window.
- `retry_enabled = true` (Microsoft reports that about 80% of failures pass on retry) and
  `parse_dependent_requests_enabled = false`: parsing would also fetch media, and a deny-by-default blob
  endpoint refuses the test agents.
- `ssl_check_enabled` defaults to true for an https URL. `ssl_cert_remaining_lifetime` stays unset
  unless you set it (1-365 days), and needs an https URL.
- `expected_status_code` accepts 100-599. The provider documents `0` as "any status below 400", but that
  is not verified here, so the module does not accept it yet.
- `timeout` accepts 30, 60, 90 or 120 seconds, the values the portal offers.

**Reachability.** The agents come from the public internet:

- With `cdn_provider = "cloudflare"` or `"azure_front_door"`, the app's own `*.azurewebsites.net`
  hostname denies everything but the CDN, so a test pointed at it always fails. Keep the default URL.
- Cloudflare with `proxied = false` sends the agents straight to that origin, which denies them.
- CDN WAF or bot rules can challenge the agents. Check a new test in nonprod before relying on it.
- **`cdn_provider = "direct"` with your own domain:** the module binds the hostname but no certificate
  (`ssl_state` and `thumbprint` are ignored), so an https test with the SSL check fails at once and pages,
  unless you bind a certificate outside Terraform. Until then, point `url` at
  `https://app-<project>-<site>-<np|prod>.azurewebsites.net/`, which `direct` leaves open.
- Host and User-Agent headers are reserved by the service and rejected by the module.

**Cost.** Standard tests are billed per execution: USD 0.0005 at the East US list price (September
2026; check the pricing calculator for your region). Five locations every 300 s is about 43,200
executions, roughly USD 21.60 a month per test. At 900 s it is a third of that. Test results are also
ingested into the workspace.

## Alerting

Three baseline metric alerts (HTTP 5xx count, plan CPU, response time) exist whenever an alert route does:
`alert_recipients` (which creates the site action group) or `extra_action_group_ids`. Four more families,
added in v4.1.0, are opt-in under `monitoring.alerts`, each `enabled = false` by default. Enabling any of
them without a route fails the plan. Every alert notifies the site action group and every
`extra_action_group_ids` entry.

```hcl
module "wordpress" {
  # ... existing configuration ...

  alert_recipients = ["ops@example.com"]

  monitoring = {
    alerts = {
      db_failure_threshold = 5 # aborted MySQL connections per alert_window_minutes
      mysql                = { enabled = true, active_connections_threshold = 150 }
      http_5xx_rate        = { enabled = true }
      health_check         = { enabled = true }
      resource_health      = { enabled = true }
    }
  }
}
```

### `mysql`: MySQL flexible server metrics

| Alert | Metric and aggregation | Fires when | Window / evaluated every |
|---|---|---|---|
| `cpu_percent` | `cpu_percent`, Average | above `cpu_percent_threshold` (80) | PT15M / PT5M |
| `memory_percent` | `memory_percent`, Average | above `memory_percent_threshold` (90) | PT15M / PT5M |
| `storage_percent` | `storage_percent`, Maximum | above `storage_percent_threshold` (85) | PT15M / PT5M |
| `aborted_connections` | `aborted_connections`, Total | above `db_failure_threshold` (5) | `alert_window_minutes` / PT1M |
| `active_connections` | `active_connections`, Maximum | above `active_connections_threshold` | PT15M / PT5M |
| `cpu_credits_remaining` | `cpu_credits_remaining`, Average | below `cpu_credits_remaining_threshold` (30) | PT30M / PT15M |

- `db_failure_threshold` was declared in earlier releases but never read. It is now the `aborted_connections`
  threshold, and only when `mysql.enabled` is true.
- `aborted_connections` uses `alert_window_minutes` as its window, like the baseline alerts. Those use it
  as given, and exist whenever this family does, so keep it at 1, 5, 15 or 30 (the default is 5).
- `active_connections` exists only when you set `active_connections_threshold`, because `max_connections`
  varies by SKU. Pick a value below your SKU's limit.
- `cpu_credits_remaining` exists only on Burstable (`B_`) SKUs. The credit metrics have 15-minute and longer
  grains, hence the longer window.
- The alert set depends on the resolved database SKU, so `database.sku_name` must be known at plan time.
  A literal, or the environment default, always is.

### `http_5xx_rate`: share of requests that fail

A log alert on `AppServiceHTTPLogs` in the site workspace. It fires when 5xx responses exceed
`threshold_percent` (5) of the production app's requests in `window_duration` (PT15M), evaluated every
`evaluation_frequency` (PT5M), and stays quiet when fewer than `minimum_requests` (20) arrived. Unlike the
baseline count alert, it neither pages on a busy site with a few errors nor misses a quiet site that fails
every request. Staging-slot traffic is excluded.

- **On a brand-new site, enable it on a second apply.** The table appears only when the first logs arrive, up
  to about 90 minutes after the app's diagnostic setting is created, and the rule can fail to create before
  then even with query validation skipped. Existing sites already stream the table.
- The rule runs with the permissions of the principal that last edited it. With an external
  `monitoring.log_analytics_workspace_id`, that principal needs read access to the workspace.
- The rule must be in its workspace's region, and is created in `location`. With an external workspace in
  another region, set `monitoring.log_analytics_workspace_location` to that workspace's region.
- `evaluation_frequency` PT1M is not offered: the rule skips query validation, which conflicts with it.
- Log alert rules are billed per rule and evaluation frequency; see Azure Monitor pricing.

### `health_check`: App Service health check

A metric alert on `HealthCheckStatus`, Average below `threshold` (100, meaning any unhealthy instance) over
`window_size` (PT15M, evaluated every PT5M). The app always has a health check path. App Service pings it
every minute but reports a failure only once an instance is judged unhealthy (10 consecutive failed pings by
default), so detection takes at least 10 minutes plus the window, and a stopped app may report nothing. Use
availability tests as the primary "site down" signal.

### `resource_health`: Azure Resource Health

An activity-log alert (location `global`) scoped to the web app, the MySQL server, the Key Vault, the storage
account, and the App Service plan when this site owns it (a shared plan is left to its owner). By default it
fires when a resource moves **into** `Degraded` or `Unavailable` from `Available` or `Unknown`, for a
`PlatformInitiated` or `Unknown` cause. It does not fire on user-initiated events (restarts, deployments,
scaling) or on recovery.

- An escalation from `Degraded` to `Unavailable` does not page again: the incident is already open. Add
  `"Degraded"` to `previous` to page on it too, at the cost of repeat pages on updates while degraded.
- Microsoft's list of Resource Health resource types does not include MySQL flexible server, although
  Microsoft announced support in 2023. Confirm an event arrives before relying on it for the database.

### Failure Anomalies (platform-created)

Azure creates a `Failure Anomalies - <component>` smart-detection alert rule, and an action group named
"Application Insights Smart Detection", next to the site's Application Insights component. Neither is in
Terraform state, and this module does not manage them.

- That action group emails every holder of the Monitoring Contributor and Monitoring Reader roles on the
  subscription.
- The rule analyses server-side request telemetry. PHP on App Service has no automatic Application Insights
  instrumentation, so unless WordPress runs an SDK the rule has nothing to analyse.
- To silence or reroute it, disable it in the portal, or adopt it with an `import` block in your root module
  (an import cannot live inside this module).
- Being unmanaged, these resources can also stop Terraform from deleting the site resource group when the
  provider's `prevent_deletion_if_contains_resources` feature is on. That is not new.

## MySQL slow query log

The MySQL diagnostic setting has always enabled the `MySqlSlowLogs` and `MySqlAuditLogs` categories, but
both stayed empty: no server parameter turned the logs on. `database.slow_query_log_enabled = true` sets
`slow_query_log = ON` and `long_query_time` (`database.long_query_time`, default 2 seconds; the server's own
default is 10).

```hcl
module "wordpress" {
  # ... existing configuration ...

  database = {
    slow_query_log_enabled = true
    long_query_time        = 2 # seconds; fractions allowed
  }
}
```

- The rows land in the site workspace, in `AzureDiagnostics` with `Category == "MySqlSlowLogs"`. Ingestion
  is billed, and a low `long_query_time` on a busy site logs a lot.
- Both parameters are dynamic: no restart. A new `long_query_time` applies to new connections only.
- Setting it back to `false` resets both parameters to their server defaults.
- Audit logging is not offered, so `MySqlAuditLogs` stays enabled and empty.

## Diagnostic settings

The app service and MySQL diagnostic settings are unconditional. Three more targets are opt-in, each through a
top-level map in the shape of the Azure Verified Modules `diagnostic_settings` interface. Each map entry
becomes one diagnostic setting; an empty map (the default) creates none.

```hcl
module "wordpress" {
  # ... existing configuration ...

  key_vault_diagnostic_settings    = { default = {} } # AuditEvent + AllMetrics to the site workspace
  storage_blob_diagnostic_settings = { default = {} } # StorageRead/Write/Delete + Transaction
  staging_slot_diagnostic_settings = { default = {} } # S* and P* SKUs only

  # Or choose categories and a destination explicitly:
  # key_vault_diagnostic_settings = {
  #   audit = {
  #     logs                  = [{ category_group = "audit" }]
  #     metrics               = []
  #     workspace_resource_id = "/subscriptions/.../workspaces/central-security"
  #   }
  # }
}
```

| Input | Target | `logs = null` sends | `metrics = null` sends | Default name |
|---|---|---|---|---|
| `key_vault_diagnostic_settings` | the site's Key Vault | `AuditEvent` | `AllMetrics` | `diag-keyvault-<site>-<key>` |
| `storage_blob_diagnostic_settings` | `<storage account>/blobServices/default` | `StorageRead`, `StorageWrite`, `StorageDelete` | `Transaction` | `diag-blob-<site>-<key>` |
| `staging_slot_diagnostic_settings` | the staging slot | the four App Service categories the app sends | `AllMetrics` | `diag-appservice-staging-<site>-<key>` |

- **Blob metrics.** `AllMetrics` is rejected for the blob service: the API expands it into `Capacity` and
  `Transaction`, so the plan would show a change on every run. List the categories you want instead.
- **Staging slot.** Only S* and P* SKUs have a slot. On any other SKU the input is ignored and the plan
  prints a warning.
- **Destination type.** `log_analytics_destination_type` defaults to null, which leaves Azure's default for
  the target (`AzureDiagnostics` for Key Vault). `"Dedicated"` selects resource-specific tables where the
  service has them, such as `AZKVAuditLogs` for Key Vault. The argument is optional and computed, so null
  does not plan a change.
- **Azure limits.** A resource takes at most five diagnostic settings, and two settings cannot send the same
  category to the same destination. Within one map the plan fails on either, and on two entries with the same
  name. A diagnostic setting that Azure Policy deploys to the vault or the storage account can still conflict
  with one of these at apply.
- **Cost.** `StorageBlobLogs` records every media read, `AuditEvent` every secret read, and the slot sends its
  own HTTP logs. All three are billed on ingestion.

**Mapping from the AVM interface, and where this module differs:**

- The attribute names match AVM's current (v2) shape: `name`, `logs` (`category`, `category_group`,
  `enabled`), `metrics` (`category`, `enabled`), `log_analytics_destination_type`, `workspace_resource_id`,
  `storage_account_resource_id`, `event_hub_authorization_rule_resource_id`, `event_hub_name` and
  `marketplace_partner_resource_id`.
- `log_analytics_destination_type` defaults to null, not AVM's `"Dedicated"`.
- With no destination at all, the setting goes to the site workspace. AVM requires one.
- Entries with `enabled = false` are dropped: azurerm has no per-category `enabled`.
- `retention_policy` is not declared. Terraform drops attributes the type does not declare, so an AVM map
  that carries it still converts, and the attribute is ignored.
- The same leniency applies to an older AVM map in the v1 shape (`log_categories`, `log_groups`,
  `metric_categories`): those attributes are dropped too, `logs` and `metrics` end up null, and the target
  defaults apply **without an error**. Rename them to `logs` and `metrics` to take effect.

## Resource locks

`lock` puts a management lock on the site resource group, in the Azure Verified Modules lock shape. The
shared-infrastructure module has the same input for the shared resource group.

```hcl
module "wordpress" {
  # ... existing configuration ...

  lock = { kind = "CanNotDelete" } # name defaults to site-protection-lock
}
```

- **Only `CanNotDelete` is accepted.** AVM also allows `ReadOnly`, but a ReadOnly lock blocks the POST list
  operations every refresh makes (storage account keys, app settings, publishing credentials). The module
  could then no longer plan, and the lock could only be removed with `-refresh=false` or outside Terraform.
- **`enable_resource_lock` still works.** `enable_resource_lock = true` and `lock = { kind = "CanNotDelete" }`
  render the same lock (`site-protection-lock`, same notes) at the same address, so switching from one to
  the other plans no change. Setting both fails the plan.
- **Permissions.** Creating or deleting a lock needs `Microsoft.Authorization/locks/*`: Owner or User Access
  Administrator have it, Contributor does not.
- **Shape.** `kind` and `name` follow the AVM lock interface. `notes` follows the current AVM spec, which
  added it; older AVM modules take only `kind` and `name`. Every lock argument forces replacement, so a new
  `name` or `notes` briefly drops the lock and recreates it.

**What a CanNotDelete lock blocks.** Azure refuses every DELETE under the locked group, including on
extension resources such as diagnostic settings and alert rules. While the lock exists, each of these fails
at apply:

- destroying the site, or removing it from a `for_each`;
- removing the staging slot (moving from S*/P* to B*), a web test, an alert, or a diagnostic-setting map
  entry, and turning an alert family back to `enabled = false`;
- any change that forces replacement, which deletes first or last: the Key Vault (purge protection,
  retention, `key_vault_name_suffix`, region), the MySQL server (`geo_redundant_backup`), a diagnostic
  setting's name or target, a web test's location or component, the 5xx-rate rule's location or scope, and
  the Resource Health alert's location;
- deleting role assignments in the group.

Turning the slow query log off still works: removing a MySQL server parameter resets it with a PUT, not a
DELETE. To make any of the changes above, remove the lock first (`lock = null`, or
`enable_resource_lock = false`), apply, make the change, then put the lock back. On a full destroy Terraform
deletes the lock before the resources it protects, but Azure's eventual consistency can still fail that
destroy; run it again.

**Shared resource group.** In shared-plan mode every site's app and staging slot live in the shared group,
together with the app's diagnostic setting. A lock there makes removing any shared-plan site, and replacing
the shared plan, fail in the same way.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.6.0 |
| <a name="requirement_azapi"></a> [azapi](#requirement\_azapi) | >= 1.13.0, < 3.0 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 5.6 |
| <a name="requirement_cloudflare"></a> [cloudflare](#requirement\_cloudflare) | ~> 5.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.5.0, < 4.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | >= 0.9.0, < 1.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azapi"></a> [azapi](#provider\_azapi) | >= 1.13.0, < 3.0 |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | ~> 5.6 |
| <a name="provider_cloudflare"></a> [cloudflare](#provider\_cloudflare) | ~> 5.0 |
| <a name="provider_random"></a> [random](#provider\_random) | >= 3.5.0, < 4.0 |
| <a name="provider_time"></a> [time](#provider\_time) | >= 0.9.0, < 1.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_app_service"></a> [app\_service](#module\_app\_service) | ../app-service | n/a |
| <a name="module_cloudflare"></a> [cloudflare](#module\_cloudflare) | ../cloudflare | n/a |
| <a name="module_database"></a> [database](#module\_database) | ../database | n/a |
| <a name="module_dns_zones"></a> [dns\_zones](#module\_dns\_zones) | ../dns-zones | n/a |
| <a name="module_front_door"></a> [front\_door](#module\_front\_door) | ../front-door | n/a |
| <a name="module_key_vault"></a> [key\_vault](#module\_key\_vault) | ../key-vault | n/a |
| <a name="module_networking"></a> [networking](#module\_networking) | ../networking | n/a |
| <a name="module_storage"></a> [storage](#module\_storage) | ../storage | n/a |

## Resources

| Name | Type |
|------|------|
| [azapi_update_resource.app_service_front_door_restriction](https://registry.terraform.io/providers/azure/azapi/latest/docs/resources/update_resource) | resource |
| [azurerm_app_service_custom_hostname_binding.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/app_service_custom_hostname_binding) | resource |
| [azurerm_application_insights.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_insights) | resource |
| [azurerm_application_insights_standard_web_test.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_insights_standard_web_test) | resource |
| [azurerm_key_vault_access_policy.app_service_update](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault_access_policy) | resource |
| [azurerm_key_vault_access_policy.staging_slot](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault_access_policy) | resource |
| [azurerm_log_analytics_workspace.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/log_analytics_workspace) | resource |
| [azurerm_management_lock.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/management_lock) | resource |
| [azurerm_monitor_action_group.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_action_group) | resource |
| [azurerm_monitor_activity_log_alert.resource_health](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_activity_log_alert) | resource |
| [azurerm_monitor_diagnostic_setting.app_service](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_diagnostic_setting) | resource |
| [azurerm_monitor_diagnostic_setting.front_door](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_diagnostic_setting) | resource |
| [azurerm_monitor_diagnostic_setting.key_vault](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_diagnostic_setting) | resource |
| [azurerm_monitor_diagnostic_setting.mysql](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_diagnostic_setting) | resource |
| [azurerm_monitor_diagnostic_setting.staging_slot](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_diagnostic_setting) | resource |
| [azurerm_monitor_diagnostic_setting.storage_blob](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_diagnostic_setting) | resource |
| [azurerm_monitor_metric_alert.availability](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_metric_alert) | resource |
| [azurerm_monitor_metric_alert.health_check](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_metric_alert) | resource |
| [azurerm_monitor_metric_alert.high_cpu](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_metric_alert) | resource |
| [azurerm_monitor_metric_alert.http_5xx](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_metric_alert) | resource |
| [azurerm_monitor_metric_alert.mysql](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_metric_alert) | resource |
| [azurerm_monitor_metric_alert.response_time](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_metric_alert) | resource |
| [azurerm_monitor_scheduled_query_rules_alert_v2.http_5xx_rate](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_scheduled_query_rules_alert_v2) | resource |
| [azurerm_resource_group.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [random_password.db](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [time_sleep.dns_propagation](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [azurerm_client_config.current](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/client_config) | data source |
| [cloudflare_ip_ranges.current](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/data-sources/ip_ranges) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_alert_recipients"></a> [alert\_recipients](#input\_alert\_recipients) | Email addresses for alert notifications | `list(string)` | `[]` | no |
| <a name="input_app_service"></a> [app\_service](#input\_app\_service) | App Service configuration | <pre>object({<br/>    plan_id                        = optional(string, null)<br/>    use_shared_plan                = optional(bool, false)<br/>    sku_name                       = optional(string, "P1v3")<br/>    always_on                      = optional(bool, true)<br/>    health_check_path              = optional(string)<br/>    worker_count                   = optional(number, 1)<br/>    extra_app_settings             = optional(map(string), {})<br/>    extra_sticky_app_setting_names = optional(list(string), [])<br/>    sticky_connection_string_names = optional(list(string), [])<br/>    staging_app_settings_override  = optional(map(string), {})<br/>    staging_always_on              = optional(bool, false)<br/>  })</pre> | `{}` | no |
| <a name="input_app_service_ftp_publish_basic_authentication_enabled"></a> [app\_service\_ftp\_publish\_basic\_authentication\_enabled](#input\_app\_service\_ftp\_publish\_basic\_authentication\_enabled) | Enable basic authentication for FTP publishing on the site and its staging slot. Defaults to true, matching the azurerm provider default. FTP is already closed at the transport layer (ftps\_state is Disabled). | `bool` | `true` | no |
| <a name="input_app_service_scm_ip_restriction_default_action"></a> [app\_service\_scm\_ip\_restriction\_default\_action](#input\_app\_service\_scm\_ip\_restriction\_default\_action) | Default action for SCM/Kudu traffic matching no app\_service\_scm\_ip\_restrictions entry. Defaults to 'Allow', matching the azurerm provider default. Set to 'Deny' to close Kudu to everything not allow-listed. | `string` | `"Allow"` | no |
| <a name="input_app_service_scm_ip_restrictions"></a> [app\_service\_scm\_ip\_restrictions](#input\_app\_service\_scm\_ip\_restrictions) | Allow-list for the App Service SCM/Kudu endpoint, applied to both the site and its staging slot. Exactly one of ip\_address, service\_tag or virtual\_network\_subnet\_id must be set per entry. Empty (the default) preserves current provider behaviour. | <pre>list(object({<br/>    ip_address                = optional(string)<br/>    service_tag               = optional(string)<br/>    virtual_network_subnet_id = optional(string)<br/>    name                      = optional(string)<br/>    priority                  = optional(number)<br/>    action                    = optional(string, "Allow")<br/>    description               = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_app_service_storage_plugin_app_settings_enabled"></a> [app\_service\_storage\_plugin\_app\_settings\_enabled](#input\_app\_service\_storage\_plugin\_app\_settings\_enabled) | Set the MICROSOFT\_AZURE\_* storage-plugin app settings on the site and its staging slot. Defaults to true, which keeps the behaviour of every earlier release. The container image does not read them (only the Microsoft Azure Storage for WordPress plugin does, as wp-config.php constants), so without that plugin they are inert, and false removes them - including the storage account key from the app's environment. The storage-key Key Vault secret is unaffected. | `bool` | `true` | no |
| <a name="input_app_service_webdeploy_publish_basic_authentication_enabled"></a> [app\_service\_webdeploy\_publish\_basic\_authentication\_enabled](#input\_app\_service\_webdeploy\_publish\_basic\_authentication\_enabled) | Enable basic authentication for WebDeploy/SCM publishing on the site and its staging slot. Defaults to true, matching the azurerm provider default. Disabling this stops FTP/S deployment from working, but does not change the FTP policy itself - ARM models the two as independent resources, so set app\_service\_ftp\_publish\_basic\_authentication\_enabled = false too. | `bool` | `true` | no |
| <a name="input_availability_tests"></a> [availability\_tests](#input\_availability\_tests) | Standard availability tests against the site's Application Insights component, one per map entry; each gets one metric alert that fires when failed\_location\_count or more locations fail. Empty (the default) creates nothing. url defaults to https://<custom\_domain><path>, so tests probe the public site through the CDN. Requires alert\_recipients or extra\_action\_group\_ids. Each test is billed per execution; see the README before adding locations or raising the frequency. | <pre>map(object({<br/>    url                              = optional(string)      # null => "https://<custom_domain><path>"<br/>    path                             = optional(string, "/") # used only when url is null<br/>    http_verb                        = optional(string, "GET")<br/>    headers                          = optional(map(string), {}) # Host and User-Agent are reserved by the service<br/>    expected_status_code             = optional(number, 200)<br/>    content_match                    = optional(string) # the test passes only if this text is found<br/>    content_match_ignore_case        = optional(bool, false)<br/>    ssl_check_enabled                = optional(bool)        # null => true when the URL is https<br/>    ssl_cert_remaining_lifetime      = optional(number)      # days, 1-365; needs an https URL and the SSL check<br/>    frequency                        = optional(number, 300) # seconds: 300, 600 or 900<br/>    timeout                          = optional(number, 30)  # seconds: 30, 60, 90 or 120<br/>    geo_locations                    = optional(list(string), ["emea-ru-msa-edge", "emea-se-sto-edge", "emea-nl-ams-azr", "emea-gb-db3-azr", "emea-fr-pra-edge"])<br/>    failed_location_count            = optional(number) # null => max(1, locations - 2)<br/>    follow_redirects_enabled         = optional(bool, true)<br/>    parse_dependent_requests_enabled = optional(bool, false) # true also fetches media, which a deny-by-default blob endpoint refuses<br/>    retry_enabled                    = optional(bool, true)<br/>    enabled                          = optional(bool, true)<br/>    alert_severity                   = optional(number, 1)<br/>    description                      = optional(string)<br/>  }))</pre> | `{}` | no |
| <a name="input_cdn_provider"></a> [cdn\_provider](#input\_cdn\_provider) | CDN provider: 'cloudflare' (uses Cloudflare CDN/WAF), 'azure\_front\_door' (uses Azure Front Door), 'direct' (no CDN) | `string` | `"direct"` | no |
| <a name="input_cloudflare"></a> [cloudflare](#input\_cloudflare) | Cloudflare configuration | <pre>object({<br/>    enabled                        = optional(bool, false)<br/>    account_id                     = optional(string, "")<br/>    domain                         = optional(string, "")<br/>    subdomain                      = optional(string, "")<br/>    proxied                        = optional(bool, true)<br/>    enable_waf                     = optional(bool, false) # Needs Pro or higher: rate limiting exceeds Free's 1 rule and 10 s timeout<br/>    enable_page_rules              = optional(bool, true)  # Free plan: 3 rules (wp-admin bypass, wp-login bypass, wp-content cache)<br/>    enable_cache_rules             = optional(bool, false) # Works on Free: 5 of the 10 cache rules it allows<br/>    enable_zone_setting_overrides  = optional(bool, false) # Some settings can't be modified on Free plan<br/>    enable_wordpress_optimizations = optional(bool, true)<br/>  })</pre> | `{}` | no |
| <a name="input_custom_domain"></a> [custom\_domain](#input\_custom\_domain) | Custom domain for the WordPress site | `string` | n/a | yes |
| <a name="input_database"></a> [database](#input\_database) | Database configuration. sku\_name, backup\_retention\_days and geo\_redundant\_backup default by environment when unset - see the Environment-aware Defaults section of the README. NOTE: geo\_redundant\_backup forces replacement of the MySQL server, so set it explicitly on an existing deployment before upgrading. mysql\_version defaults to 8.0.21; changing it on an existing server is an irreversible major-version upgrade (plan it per agenticcodingops/trackroutinely#104, WP-43). slow\_query\_log\_enabled (default false) sets the slow\_query\_log and long\_query\_time server parameters (long\_query\_time defaults to 2 seconds), so the MySqlSlowLogs category of the MySQL diagnostic setting carries rows. | <pre>object({<br/>    sku_name                  = optional(string)<br/>    storage_size_gb           = optional(number, 100)<br/>    storage_iops              = optional(number, 700)<br/>    backup_retention_days     = optional(number)<br/>    geo_redundant_backup      = optional(bool)<br/>    high_availability_mode    = optional(string, "Disabled")<br/>    storage_auto_grow_enabled = optional(bool, true)<br/>    # Constant default, not environment-aware. See mysql_version in modules/database.<br/>    mysql_version = optional(string, "8.0.21")<br/>    # Opt-in slow query log; constant defaults. Audit logging is not offered.<br/>    slow_query_log_enabled = optional(bool, false)<br/>    long_query_time        = optional(number, 2)<br/>  })</pre> | `{}` | no |
| <a name="input_deployer_object_id"></a> [deployer\_object\_id](#input\_deployer\_object\_id) | Object ID of the principal that runs terraform apply; it gets the Terraform secret-management access policy on the site's Key Vault. Null (the default) keeps the module's own azurerm\_client\_config read. Set it, together with deployer\_tenant\_id, only when plan and apply run as different identities or when the caller needs its own depends\_on on this module; pass a lowercase value known at plan time. The policy's object\_id forces replacement, so a value that differs from the principal that created the existing policy replaces it: do that only as a planned identity cutover. | `string` | `null` | no |
| <a name="input_deployer_tenant_id"></a> [deployer\_tenant\_id](#input\_deployer\_tenant\_id) | Tenant ID of the principal that runs terraform apply, used on its Key Vault access policy. Null (the default) keeps the module's own azurerm\_client\_config read. Set it together with deployer\_object\_id, as a lowercase value. | `string` | `null` | no |
| <a name="input_enable_resource_lock"></a> [enable\_resource\_lock](#input\_enable\_resource\_lock) | Put a CanNotDelete lock (site-protection-lock) on the site resource group. Superseded by lock, and kept: true is equivalent to lock = { kind = "CanNotDelete" }, so switching plans no change. Do not set both. Needs Microsoft.Authorization/locks/* (Owner or User Access Administrator; Contributor lacks it). See the README's Resource locks section before enabling. | `bool` | `false` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name (nonprod or production) | `string` | n/a | yes |
| <a name="input_extra_action_group_ids"></a> [extra\_action\_group\_ids](#input\_extra\_action\_group\_ids) | Additional action group resource IDs that every alert in this module notifies, alongside the site action group (which exists only when alert\_recipients is non-empty). Use it to attach a platform-level group. Empty (the default) changes nothing. With no alert\_recipients, setting it still creates the three baseline alerts (HTTP 5xx, CPU, response time), routed to these groups only. | `list(string)` | `[]` | no |
| <a name="input_extra_secret_app_settings"></a> [extra\_secret\_app\_settings](#input\_extra\_secret\_app\_settings) | Map of App Service app setting name => secret name in the site's Key Vault. Each entry is rendered as @Microsoft.KeyVault(SecretUri=...) and applied to both the production app and the staging slot. Takes precedence over app\_service.extra\_app\_settings on key collision. | `map(string)` | `{}` | no |
| <a name="input_extra_secrets"></a> [extra\_secrets](#input\_extra\_secrets) | Additional secrets to store in the site's Key Vault, as secret name => value. Module-owned names (db-password, storage-key, appinsights-connection) take precedence and cannot be overridden. Keys must be known at plan time. | `map(string)` | `{}` | no |
| <a name="input_front_door"></a> [front\_door](#input\_front\_door) | Front Door configuration | <pre>object({<br/>    enabled               = optional(bool, true)<br/>    sku_name              = optional(string, "Premium_AzureFrontDoor")<br/>    waf_mode              = optional(string)<br/>    cache_uploads_minutes = optional(number, 180)<br/>    cache_static_minutes  = optional(number, 180)<br/>  })</pre> | `{}` | no |
| <a name="input_key_vault_diagnostic_settings"></a> [key\_vault\_diagnostic\_settings](#input\_key\_vault\_diagnostic\_settings) | Diagnostic settings for the site's Key Vault, AVM diagnostic\_settings shape, one setting per map entry. Empty (the default) creates none. logs = null sends AuditEvent; metrics = null sends AllMetrics. With no destination set, it sends to the site workspace. | <pre>map(object({<br/>    name = optional(string, null) # null => diag-<target>-<site_name>-<map key><br/>    logs = optional(set(object({  # null => the target's default categories<br/>      category       = optional(string, null)<br/>      category_group = optional(string, null)<br/>      enabled        = optional(bool, true) # false entries are dropped<br/>    })))<br/>    metrics = optional(set(object({ # null => the target's default metrics<br/>      category = optional(string, "AllMetrics")<br/>      enabled  = optional(bool, true)<br/>    })))<br/>    log_analytics_destination_type           = optional(string, null) # AVM defaults to "Dedicated"; null leaves Azure's default<br/>    workspace_resource_id                    = optional(string, null) # null, with no other destination => the site workspace<br/>    storage_account_resource_id              = optional(string, null)<br/>    event_hub_authorization_rule_resource_id = optional(string, null)<br/>    event_hub_name                           = optional(string, null)<br/>    marketplace_partner_resource_id          = optional(string, null)<br/>  }))</pre> | `{}` | no |
| <a name="input_key_vault_name_suffix"></a> [key\_vault\_name\_suffix](#input\_key\_vault\_name\_suffix) | Suffix appended to Key Vault name. Bump this to avoid conflicts with soft-deleted vaults that have purge protection enabled. | `string` | `"9"` | no |
| <a name="input_key_vault_network_acls_ip_rules"></a> [key\_vault\_network\_acls\_ip\_rules](#input\_key\_vault\_network\_acls\_ip\_rules) | Public IPv4 addresses or CIDRs permitted to reach the Key Vault data plane. Add the deploying principal's egress IP (e.g. the CI runner). | `list(string)` | `[]` | no |
| <a name="input_key_vault_network_acls_virtual_network_subnet_ids"></a> [key\_vault\_network\_acls\_virtual\_network\_subnet\_ids](#input\_key\_vault\_network\_acls\_virtual\_network\_subnet\_ids) | Extra subnet IDs permitted to reach the Key Vault data plane. The site's App Service subnet is always included. | `list(string)` | `[]` | no |
| <a name="input_key_vault_public_network_access_enabled"></a> [key\_vault\_public\_network\_access\_enabled](#input\_key\_vault\_public\_network\_access\_enabled) | Allow unrestricted public access to the Key Vault data plane. Defaults to false (deny). Terraform is not a trusted Azure service, so its calls to create secrets need either an entry in key\_vault\_network\_acls\_ip\_rules or this set to true. | `bool` | `false` | no |
| <a name="input_key_vault_purge_protection_enabled"></a> [key\_vault\_purge\_protection\_enabled](#input\_key\_vault\_purge\_protection\_enabled) | Enable Key Vault purge protection. Defaults by environment when unset: true in production, false in nonprod. WARNING: Azure permits enabling this but never disabling it, so changing it on an existing vault forces a destroy and recreate. | `bool` | `null` | no |
| <a name="input_key_vault_soft_delete_retention_days"></a> [key\_vault\_soft\_delete\_retention\_days](#input\_key\_vault\_soft\_delete\_retention\_days) | Days a soft-deleted vault is retained (7-90). Defaults by environment when unset: 90 in production, 7 in nonprod. Azure fixes this at creation, so changing it on an existing vault forces a destroy and recreate. | `number` | `null` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region for all resources | `string` | n/a | yes |
| <a name="input_lock"></a> [lock](#input\_lock) | Resource lock on the site resource group, in the Azure Verified Modules lock shape. null (the default) means no lock unless enable\_resource\_lock is true; do not set both. Only kind = "CanNotDelete" is accepted. name defaults to site-protection-lock and notes to the enable\_resource\_lock wording, so lock = { kind = "CanNotDelete" } plans no change against enable\_resource\_lock = true. Needs Microsoft.Authorization/locks/* (Owner or User Access Administrator; Contributor lacks it). While it exists, every removal or replacement in the group fails at apply: see the README's Resource locks section. | <pre>object({<br/>    kind  = string<br/>    name  = optional(string, null)<br/>    notes = optional(string, null) # in the current AVM lock spec; older AVM modules take only kind and name<br/>  })</pre> | `null` | no |
| <a name="input_monitoring"></a> [monitoring](#input\_monitoring) | Monitoring configuration. alerts.mysql, alerts.http\_5xx\_rate, alerts.health\_check and alerts.resource\_health are opt-in alert families (enabled = false by default); enabling any of them needs alert\_recipients or extra\_action\_group\_ids. db\_failure\_threshold is the aborted-connections threshold of the MySQL family. log\_analytics\_workspace\_location is the region of an external log\_analytics\_workspace\_id: set it when that workspace is in another region and http\_5xx\_rate is enabled, because a log search alert rule must be in its workspace's region. See the README's Alerting section. | <pre>object({<br/>    log_analytics_workspace_id       = optional(string, null)<br/>    log_analytics_workspace_location = optional(string) # the external workspace's region; see http_5xx_rate<br/>    retention_days                   = optional(number)<br/>    alerts = optional(object({<br/>      http_5xx_threshold   = optional(number, 10)<br/>      high_cpu_threshold   = optional(number, 80)<br/>      db_failure_threshold = optional(number, 5)<br/>      alert_window_minutes = optional(number, 5)<br/>      mysql = optional(object({<br/>        enabled                         = optional(bool, false)<br/>        severity                        = optional(number, 2)<br/>        cpu_percent_threshold           = optional(number, 80)<br/>        memory_percent_threshold        = optional(number, 90)<br/>        storage_percent_threshold       = optional(number, 85)<br/>        active_connections_threshold    = optional(number)     # null => no active_connections alert (max_connections varies by SKU)<br/>        cpu_credits_remaining_threshold = optional(number, 30) # Burstable (B_) SKUs only<br/>      }), {})<br/>      http_5xx_rate = optional(object({<br/>        enabled              = optional(bool, false)<br/>        severity             = optional(number, 2)<br/>        threshold_percent    = optional(number, 5)<br/>        minimum_requests     = optional(number, 20)<br/>        window_duration      = optional(string, "PT15M")<br/>        evaluation_frequency = optional(string, "PT5M") # PT1M is not offered<br/>      }), {})<br/>      health_check = optional(object({<br/>        enabled     = optional(bool, false)<br/>        severity    = optional(number, 1)<br/>        threshold   = optional(number, 100)<br/>        window_size = optional(string, "PT15M")<br/>      }), {})<br/>      resource_health = optional(object({<br/>        enabled  = optional(bool, false)<br/>        current  = optional(list(string), ["Degraded", "Unavailable"])<br/>        previous = optional(list(string), ["Available", "Unknown"])<br/>        reasons  = optional(list(string), ["PlatformInitiated", "Unknown"])<br/>      }), {})<br/>    }), {})<br/>  })</pre> | `{}` | no |
| <a name="input_networking"></a> [networking](#input\_networking) | Networking configuration | <pre>object({<br/>    vnet_address_space           = optional(string, "10.0.0.0/16")<br/>    app_subnet_cidr              = optional(string, "10.0.0.0/24")<br/>    db_subnet_cidr               = optional(string, "10.0.1.0/24")<br/>    private_endpoint_subnet_cidr = optional(string, "10.0.2.0/24")<br/>  })</pre> | `{}` | no |
| <a name="input_plan_density_limit"></a> [plan\_density\_limit](#input\_plan\_density\_limit) | DEPRECATED, and has no effect: nothing in this module reads it, so it enforces no limit on sites per App Service Plan. It is kept, with its validation, only so existing configurations that set it still plan, and will be removed in the next major release. Remove it from your configuration. | `number` | `10` | no |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name used in resource naming (lowercase, 2-24 chars) | `string` | n/a | yes |
| <a name="input_shared_plan_sku"></a> [shared\_plan\_sku](#input\_shared\_plan\_sku) | SKU of the shared App Service Plan. Required when app\_service.use\_shared\_plan = true to determine feature availability. | `string` | `null` | no |
| <a name="input_shared_resource_group_name"></a> [shared\_resource\_group\_name](#input\_shared\_resource\_group\_name) | Name of the shared resource group where the shared App Service Plan is located. Required when app\_service.use\_shared\_plan = true. | `string` | `null` | no |
| <a name="input_site_name"></a> [site\_name](#input\_site\_name) | Site name used for resource naming (lowercase, hyphens only) | `string` | n/a | yes |
| <a name="input_staging_slot_diagnostic_settings"></a> [staging\_slot\_diagnostic\_settings](#input\_staging\_slot\_diagnostic\_settings) | Diagnostic settings for the staging slot, AVM diagnostic\_settings shape, one setting per map entry. Empty (the default) creates none. Only S* and P* SKUs have a slot; on any other SKU this input is ignored, with a warning. logs = null sends the four App Service categories the production app sends; metrics = null sends AllMetrics. With no destination set, it sends to the site workspace. | <pre>map(object({<br/>    name = optional(string, null) # null => diag-<target>-<site_name>-<map key><br/>    logs = optional(set(object({  # null => the target's default categories<br/>      category       = optional(string, null)<br/>      category_group = optional(string, null)<br/>      enabled        = optional(bool, true) # false entries are dropped<br/>    })))<br/>    metrics = optional(set(object({ # null => the target's default metrics<br/>      category = optional(string, "AllMetrics")<br/>      enabled  = optional(bool, true)<br/>    })))<br/>    log_analytics_destination_type           = optional(string, null) # AVM defaults to "Dedicated"; null leaves Azure's default<br/>    workspace_resource_id                    = optional(string, null) # null, with no other destination => the site workspace<br/>    storage_account_resource_id              = optional(string, null)<br/>    event_hub_authorization_rule_resource_id = optional(string, null)<br/>    event_hub_name                           = optional(string, null)<br/>    marketplace_partner_resource_id          = optional(string, null)<br/>  }))</pre> | `{}` | no |
| <a name="input_storage"></a> [storage](#input\_storage) | Storage account configuration | <pre>object({<br/>    additional_containers           = optional(map(object({ access_type = optional(string, "private") })), {})<br/>    versioning_enabled              = optional(bool, true)<br/>    blob_delete_retention_days      = optional(number, 30)<br/>    container_delete_retention_days = optional(number, 30)<br/>    lifecycle_policy_enabled        = optional(bool, true)<br/>    lifecycle_cool_tier_days        = optional(number, 30)<br/>    lifecycle_version_delete_days   = optional(number, 90)<br/>    lifecycle_snapshot_delete_days  = optional(number, 90)<br/>    lifecycle_prefix_match          = optional(list(string), ["uploads/"])<br/>  })</pre> | `{}` | no |
| <a name="input_storage_blob_diagnostic_settings"></a> [storage\_blob\_diagnostic\_settings](#input\_storage\_blob\_diagnostic\_settings) | Diagnostic settings for the storage account's blob service, AVM diagnostic\_settings shape, one setting per map entry. Empty (the default) creates none. logs = null sends StorageRead, StorageWrite and StorageDelete; metrics = null sends Transaction. AllMetrics is rejected: the API expands it into Capacity and Transaction, which plans a change on every run. With no destination set, it sends to the site workspace. | <pre>map(object({<br/>    name = optional(string, null) # null => diag-<target>-<site_name>-<map key><br/>    logs = optional(set(object({  # null => the target's default categories<br/>      category       = optional(string, null)<br/>      category_group = optional(string, null)<br/>      enabled        = optional(bool, true) # false entries are dropped<br/>    })))<br/>    metrics = optional(set(object({ # null => the target's default metrics<br/>      category = optional(string, "AllMetrics")<br/>      enabled  = optional(bool, true)<br/>    })))<br/>    log_analytics_destination_type           = optional(string, null) # AVM defaults to "Dedicated"; null leaves Azure's default<br/>    workspace_resource_id                    = optional(string, null) # null, with no other destination => the site workspace<br/>    storage_account_resource_id              = optional(string, null)<br/>    event_hub_authorization_rule_resource_id = optional(string, null)<br/>    event_hub_name                           = optional(string, null)<br/>    marketplace_partner_resource_id          = optional(string, null)<br/>  }))</pre> | `{}` | no |
| <a name="input_storage_network_rules_bypass"></a> [storage\_network\_rules\_bypass](#input\_storage\_network\_rules\_bypass) | Traffic permitted to bypass the storage network rules. Valid values: AzureServices, Logging, Metrics, None. | `set(string)` | <pre>[<br/>  "AzureServices"<br/>]</pre> | no |
| <a name="input_storage_network_rules_default_action"></a> [storage\_network\_rules\_default\_action](#input\_storage\_network\_rules\_default\_action) | Default action for the storage account's network rules. Defaults to Deny. Set to 'Allow' if media is served straight from the blob endpoint rather than through a CDN custom domain. | `string` | `"Deny"` | no |
| <a name="input_storage_network_rules_ip_rules"></a> [storage\_network\_rules\_ip\_rules](#input\_storage\_network\_rules\_ip\_rules) | Extra public IPv4 addresses or CIDRs permitted to reach the storage data plane. Cloudflare's live IPv4 egress ranges are added automatically when cdn\_provider = 'cloudflare'. Azure Storage rejects IPv6 CIDRs and /31-/32 prefixes. | `list(string)` | `[]` | no |
| <a name="input_storage_network_rules_virtual_network_subnet_ids"></a> [storage\_network\_rules\_virtual\_network\_subnet\_ids](#input\_storage\_network\_rules\_virtual\_network\_subnet\_ids) | Extra subnet IDs permitted to reach the storage data plane. The site's App Service subnet is always included. | `list(string)` | `[]` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to all resources | `map(string)` | `{}` | no |
| <a name="input_tenant_id"></a> [tenant\_id](#input\_tenant\_id) | Azure AD tenant ID | `string` | n/a | yes |
| <a name="input_wordpress_version"></a> [wordpress\_version](#input\_wordpress\_version) | Passed to app-service as docker\_image\_tag (the name is historical). Tag of Microsoft's WordPress container image (appsvc/wordpress-debian-php): the PHP version, not a WordPress version. Floating tags exist for 8.2 and 8.3 only; the 8.4 series is published as dated tags (for example 8.4\_20260922.3.tuxprod), so "8.4" alone does not exist on the registry. A dated tag (8.x\_YYYYMMDD.N.tuxprod) disables automatic platform image updates, which makes image patching the consumer's job. | `string` | `"8.3"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_action_group_id"></a> [action\_group\_id](#output\_action\_group\_id) | ID of the site action group, for routing your own alerts to the same recipients. Null when alert\_recipients is empty (no group is created). |
| <a name="output_app_insights_id"></a> [app\_insights\_id](#output\_app\_insights\_id) | Application Insights ID |
| <a name="output_app_insights_name"></a> [app\_insights\_name](#output\_app\_insights\_name) | Application Insights name |
| <a name="output_app_service_default_hostname"></a> [app\_service\_default\_hostname](#output\_app\_service\_default\_hostname) | Web App default hostname |
| <a name="output_app_service_id"></a> [app\_service\_id](#output\_app\_service\_id) | Web App ID |
| <a name="output_app_service_name"></a> [app\_service\_name](#output\_app\_service\_name) | Web App name |
| <a name="output_app_service_plan_id"></a> [app\_service\_plan\_id](#output\_app\_service\_plan\_id) | App Service Plan ID |
| <a name="output_app_service_principal_id"></a> [app\_service\_principal\_id](#output\_app\_service\_principal\_id) | Web App managed identity principal ID. Use this to grant the site access to resources the module does not own, without re-reading the app via a data source. |
| <a name="output_availability_test_ids"></a> [availability\_test\_ids](#output\_availability\_test\_ids) | Map of availability\_tests key to standard web test ID. Empty when no tests are configured. |
| <a name="output_cdn_provider"></a> [cdn\_provider](#output\_cdn\_provider) | Active CDN provider |
| <a name="output_cloudflare_dns_hostname"></a> [cloudflare\_dns\_hostname](#output\_cloudflare\_dns\_hostname) | DNS hostname managed by Cloudflare |
| <a name="output_cloudflare_nameservers"></a> [cloudflare\_nameservers](#output\_cloudflare\_nameservers) | Cloudflare nameservers for this zone |
| <a name="output_cloudflare_proxied"></a> [cloudflare\_proxied](#output\_cloudflare\_proxied) | Whether Cloudflare proxy (CDN) is active |
| <a name="output_cloudflare_zone_id"></a> [cloudflare\_zone\_id](#output\_cloudflare\_zone\_id) | Cloudflare zone ID (when cdn\_provider = cloudflare) |
| <a name="output_custom_domain_validation_token"></a> [custom\_domain\_validation\_token](#output\_custom\_domain\_validation\_token) | TXT record value for custom domain validation |
| <a name="output_database_name"></a> [database\_name](#output\_database\_name) | WordPress database name |
| <a name="output_database_server_fqdn"></a> [database\_server\_fqdn](#output\_database\_server\_fqdn) | MySQL server FQDN |
| <a name="output_database_server_id"></a> [database\_server\_id](#output\_database\_server\_id) | MySQL server ID |
| <a name="output_database_server_name"></a> [database\_server\_name](#output\_database\_server\_name) | MySQL server name |
| <a name="output_front_door_endpoint_hostname"></a> [front\_door\_endpoint\_hostname](#output\_front\_door\_endpoint\_hostname) | Front Door endpoint hostname (for DNS CNAME) |
| <a name="output_front_door_profile_id"></a> [front\_door\_profile\_id](#output\_front\_door\_profile\_id) | Front Door profile ID |
| <a name="output_front_door_resource_guid"></a> [front\_door\_resource\_guid](#output\_front\_door\_resource\_guid) | Front Door profile resource GUID (for App Service IP restriction) |
| <a name="output_key_vault_id"></a> [key\_vault\_id](#output\_key\_vault\_id) | Key Vault ID |
| <a name="output_key_vault_secret_versionless_uris"></a> [key\_vault\_secret\_versionless\_uris](#output\_key\_vault\_secret\_versionless\_uris) | Map of Key Vault secret names to versionless URIs, including any supplied via extra\_secrets |
| <a name="output_key_vault_uri"></a> [key\_vault\_uri](#output\_key\_vault\_uri) | Key Vault URI |
| <a name="output_log_analytics_workspace_id"></a> [log\_analytics\_workspace\_id](#output\_log\_analytics\_workspace\_id) | Log Analytics Workspace ID |
| <a name="output_resource_group_id"></a> [resource\_group\_id](#output\_resource\_group\_id) | ID of the resource group |
| <a name="output_resource_group_name"></a> [resource\_group\_name](#output\_resource\_group\_name) | Name of the resource group |
| <a name="output_site_name"></a> [site\_name](#output\_site\_name) | The site name |
| <a name="output_staging_slot_hostname"></a> [staging\_slot\_hostname](#output\_staging\_slot\_hostname) | Staging slot hostname |
| <a name="output_staging_slot_principal_id"></a> [staging\_slot\_principal\_id](#output\_staging\_slot\_principal\_id) | Staging slot managed identity principal ID |
| <a name="output_storage_account_name"></a> [storage\_account\_name](#output\_storage\_account\_name) | Storage Account name |
| <a name="output_storage_additional_container_names"></a> [storage\_additional\_container\_names](#output\_storage\_additional\_container\_names) | Additional storage container names created |
| <a name="output_storage_blob_endpoint"></a> [storage\_blob\_endpoint](#output\_storage\_blob\_endpoint) | Storage blob endpoint |
| <a name="output_vnet_id"></a> [vnet\_id](#output\_vnet\_id) | Virtual Network ID |
| <a name="output_vnet_name"></a> [vnet\_name](#output\_vnet\_name) | Virtual Network name |
| <a name="output_wordpress_admin_url"></a> [wordpress\_admin\_url](#output\_wordpress\_admin\_url) | WordPress admin URL |
| <a name="output_wordpress_url"></a> [wordpress\_url](#output\_wordpress\_url) | WordPress site URL |
<!-- END_TF_DOCS -->
