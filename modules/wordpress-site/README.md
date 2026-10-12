# WordPress Site Module

Complete WordPress deployment composition module that orchestrates all sub-modules.

## Overview

This module creates a complete WordPress site deployment including:
- Resource Group
- Virtual Network with subnets
- MySQL Flexible Server on a delegated subnet, resolved through a private DNS zone (no private endpoint)
- Storage account (private uploads container, App Service backup target); media stays on the app's `/home` storage by default
- Key Vault for secrets management
- App Service with managed identity
- Log Analytics, Application Insights, diagnostic settings and alerts, created in this module. It does not call
  `modules/monitoring`.
- Optional CDN: Cloudflare or Azure Front Door, chosen by `cdn_provider`

Diagrams of the deployment order, request flows, secrets, network and monitoring are in
[docs/architecture.md](../../docs/architecture.md).

## Upgrading

Upgrade notes for this module are in the [upgrade guide](../../docs/upgrading/README.md).

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

### Binding Cloudflare rules to your zone

Cloudflare's IP ranges are shared. Set `app_service.cdn_origin_header_name = "x_azure_fdid"` and pass one to
eight UUIDs through the sensitive top-level `cdn_origin_header_values` to require the same bearer value on every
Cloudflare allow rule for the app and staging slot. Configure an edge Request Header Transform Rule to overwrite
`X-Azure-FDID` first. The health-probe, Front Door, and SCM rules remain unchanged. The default is off.

The secret exists in state, App Service configuration, and the edge rule. Load it from a secret store and first
verify that the application ignores the header. Enable the edge rule before enabling the origin filter; reverse
that order to roll back. For a no-downtime rotation, accept both values, switch the edge, then remove the old one.
Set `app_service_ip_security_audit_logs_enabled = true` if the workspace should also receive
`AppServiceIPSecAuditLogs` showing requests matched by named access rules.

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
every request. Staging-slot traffic is excluded, and so is traffic to the app's own Kudu (SCM) host, its default
hostname with `scm` after the first label, matched exactly. That includes
the SSH tunnel that deployments and ops tooling open, whose `/AppServiceTunnel/` calls return 502 in normal use.
Through v4.1.0 those counted, so a deploy on a quiet site could page with no visitor affected.

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

## Passwordless database access (managed identity)

By default the app logs in to MySQL with the `wpadmin` password, which reaches it as a Key Vault reference in
`DATABASE_PASSWORD`. This feature lets the production app log in with a Microsoft Entra token instead, one
stage at a time, so each step can be applied, checked and rolled back on its own. **Everything is off by
default**: a plan that sets none of the inputs below is unchanged, apart from the new `mysql_entra_stage`
output (`0`).

**The module does not create the identities, grant Microsoft Graph permissions or create MySQL users.** You
create the user-assigned identities, you grant any Graph permission (Layout A below), and you create the
non-administrator MySQL user yourself (`CREATE AADUSER`, run as the Entra administrator). The module only
attaches what you pass in, sets the administrator, and changes the app settings and the server parameter.

### Two layouts

- **Layout B (the simple one).** The app's own user-assigned identity is the server's Microsoft Entra
  administrator. It needs **no Microsoft Graph permission**. The administrator's `object_id` is that identity's
  `principal_id` when the principal (object) ID is the value your rehearsal proved, or its `client_id` when the
  client ID is (see "Which ID is the administrator's `object_id`" below), and the app's database user is the
  administrator's `login`. The server identity (`mysql_entra_server_identity`) can be that same identity.
- **Layout A (separate roles).** A separate server identity holds the Microsoft Graph application permissions
  `User.Read.All`, `GroupMember.Read.All` and `Application.Read.All` (granted by you, outside the module). The
  administrator is a person or a group, and the app's identity maps to a **non-administrator** MySQL user. A
  rehearsal showed why: `CREATE AADUSER '<name>' IDENTIFIED BY '<client id>'` fails with error 9127 unless the
  server identity holds those permissions, and a group as administrator also failed without them.

```hcl
# Layout B: the administrator is the app's own identity.
module "wordpress" {
  # ... existing configuration ...

  mysql_entra_server_identity = { id = "<resource-id>", client_id = "<client-id>", principal_id = "<object-id>" }
  mysql_entra_app_identity    = { id = "<resource-id>", client_id = "<client-id>", principal_id = "<object-id>" }
  mysql_entra_admin           = { login = "wp-app", object_id = "<proven-id>", tenant_id = "<tenant-id>" } # <proven-id>: the app identity's principal_id, or its client_id: see below
  mysql_entra_app_database_user = "wp-app"                                                                  # = mysql_entra_admin.login

  mysql_entra_stage_identity_enabled = true # stage 1; add the later flags one apply at a time
}
```

`mysql_entra_admin.login` and `mysql_entra_app_database_user` are MySQL user names, so each is at most 32
characters (a longer value fails at plan).

#### Which ID is the administrator's `object_id`

The module passes `mysql_entra_admin.object_id` to the provider **exactly as given** and does not translate
it. The azurerm documentation says that for a managed identity it should be the identity's **client ID**. The
design's rehearsal on a real server set the administrator by the identity's **principal (object) ID**, and
that worked. These disagree, so **confirm on the first stage-1 apply on a non-production server, and use the
value your rehearsal proved**. In Layout B the equality is `mysql_entra_admin.object_id ==
mysql_entra_app_identity.principal_id` when the principal ID is the proven value, or
`mysql_entra_app_identity.client_id` when the client ID is.

### The stages

Four flat flags, each `false` by default, each requiring the one before it (turning on a later flag alone fails
at plan). Apply, check the site, then turn on the next one.

| Stage | Flag | What changes |
| --- | --- | --- |
| 1. Identity and administrator | `mysql_entra_stage_identity_enabled` | Attaches `mysql_entra_server_identity` to the MySQL server, creates the `azurerm_mysql_flexible_server_active_directory_administrator`, and attaches `mysql_entra_app_identity` to the **production app only** (it becomes `SystemAssigned, UserAssigned`). `key_vault_reference_identity_id` stays unset, so Key Vault references keep resolving with the system-assigned identity. **No app setting changes**, so the app still uses its password. The administrator is created `mysql_entra_admin_wait_seconds` (default 30, 0 to 300) after the server, because a freshly attached identity can still be propagating and the API then fails transiently. |
| 2. App switch | `mysql_entra_stage_app_switch_enabled` | **Check the prerequisite below first.** Sets `ENABLE_MYSQL_MANAGED_IDENTITY=true`, `ENTRA_CLIENT_ID` (the app identity's client ID) and `DATABASE_USERNAME` (`mysql_entra_app_database_user`) on the production app. The container restarts; on the Microsoft image that was measured with no failed request. `app_service.extra_app_settings` and `extra_secret_app_settings` may not name these three settings: they would override the staged value, so the plan fails. |
| 3. Drop the password | `mysql_entra_stage_drop_password_enabled` | Removes `DATABASE_PASSWORD` from the production app. The `db-password` Key Vault secret is **still written**, because the way back needs it. `extra_app_settings` and `extra_secret_app_settings` may not name `DATABASE_PASSWORD` while this stage is on, or they would put it back. |
| 4. Entra only | `mysql_entra_stage_aad_only_enabled` | Creates an `azurerm_mysql_flexible_server_configuration` that sets `aad_auth_only = ON` (in the composition, ordered after the app update), so password logins stop working for everyone, the `wpadmin` administrator included. |

The `mysql_entra_stage` output reports `0` to `4` (the number of flags on), known at plan time.

Apply one stage per apply for a controlled rollout; enabling several at once is ordered safely (the app switch happens before Entra-only authentication) but gives you no point to verify between them.

None of the stage changes replaces the MySQL server or the web app: the server's `identity` block, the
administrator's `identity_id`, `login`, `object_id` and `tenant_id`, and the `aad_auth_only` value are all
updated in place by azurerm 5.x, and the web app's `identity` block is too. Two things still need care.
Turning the flags back off removes the identity and administrator again, and the deploying principal needs
Managed Identity Operator on both identities.

### Prerequisite before stage 2: the site's `wp-config.php` must carry the managed-identity block

Stage 2 only flips app settings. The image reads `ENABLE_MYSQL_MANAGED_IDENTITY` from a block that its **first
install** wrote into the site's persistent `wp-config.php`. A site whose `wp-config.php` was written by an image
older than the image's managed-identity support has no such block: with the settings flipped it would not
acquire tokens and **would lose database access**. A site installed on a recent image already has the block (the
design's rehearsal found it written at first install), but check; do not assume.

1. **Check, read-only.** Open an SSH session to the production app and run:

   ```sh
   grep -c ENABLE_MYSQL_MANAGED_IDENTITY /home/site/wwwroot/wp-config.php
   ```

   A **non-zero** count means the block is present: go ahead with stage 2.
2. **If the count is `0`**, the block is missing. The upstream procedure is under "Updating WordPress to use
   managed identity" in the image's own guide,
   <https://github.com/Azure/wordpress-linux-appservice/blob/main/WordPress/wordpress_enable_managed_identity_with_mysql.md>:
   clear the `MANAGED_IDENTITY_SETUP_COMPLETED` marker, then run `/usr/local/bin/managed-identity-setup.sh`.
   **That script also deletes and re-copies the App Service Email plugin**, so read the guide first and take a
   backup. It is a step **you** run, inside the container and outside this module: the module neither runs nor
   automates it, and nothing here vendors the script.
3. Re-run the check and confirm a non-zero count, then turn stage 2 on.

### The staging slot

The slot is never given the app identity and **keeps its password settings at every stage**: it still
reaches the database with `DATABASE_USERNAME` and `DATABASE_PASSWORD` as before.

- **Stage 1:** nothing changes for the slot.
- **Stage 2:** the production app gets the three new settings; the slot does not, so it keeps
  `ENABLE_MYSQL_MANAGED_IDENTITY` unset. With a slot, the names `ENABLE_MYSQL_MANAGED_IDENTITY`,
  `ENTRA_CLIENT_ID`, `DATABASE_USERNAME` and `DATABASE_PASSWORD` are added to the app's sticky settings, so a
  swap leaves each side's own database login where it is. (`app_service.extra_sticky_app_setting_names` is
  unchanged and still merged in.)
- **Stage 3:** `DATABASE_PASSWORD` leaves the production app only; the slot keeps it.
- **Stage 4:** `aad_auth_only` would lock the slot out, so stage 4 **fails at plan while a slot exists**
  (`app_service.staging_slot_enabled` true on an S\* or P\* SKU). Set `app_service.staging_slot_enabled = false`
  first, which destroys the slot (see [Staging Deployment Slots](#staging-deployment-slots)).

### The token cache must stay off

The image's token helper can cache the access token (`CACHE_MYSQL_ACCESS_TOKEN=true`). That makes it start a
PHP session on every request: anonymous responses get a `PHPSESSID` cookie without `Secure` or `HttpOnly` and
with no-cache headers, and each request writes a session file holding a token. Left unset, there is no
session, and each request fetches a token from the local identity endpoint (about 60 ms at the median, 100 ms
at the 95th percentile in the rehearsal). So with stage 2 on, `app_service.extra_app_settings` may not set
`CACHE_MYSQL_ACCESS_TOKEN` to `true`; the plan fails if it does. A Key Vault value cannot be read at plan, so
naming `CACHE_MYSQL_ACCESS_TOKEN` or `DB_SSL_CONNECTION` in `extra_secret_app_settings` is refused too.

### TLS

PHP connects with TLS by default (`DB_SSL_CONNECTION` defaults to true, which sets `MYSQLI_CLIENT_SSL`) but does
**not verify the server certificate**; the image's MariaDB client verifies only when it is given
`--ssl-verify-server-cert --ssl-ca=...`. With the server parameter `require_secure_transport = OFF`, which this
module has always set, the server also accepts a token login without TLS. So with stage 2 on,
`app_service.extra_app_settings` may not set `DB_SSL_CONNECTION` to `false` (the plan fails), and
`mysql_require_secure_transport = true` sets the parameter to `ON`. That is a hardening input, not a stage: the
default `false` keeps `OFF`, and turning it on refuses any client that does not use TLS, so check first.

### WP-CLI

WP-CLI reads the token through `wp-config.php`, so `wp db export` and `wp db import` work with no password
setting. For a non-administrator MySQL user, `wp db export` needs `--no-tablespaces`, which WP-CLI rewrites if
you pass it directly; load it from an option file with `--defaults` instead.

### Rolling back

Go in the reverse order, one apply per step, and re-add the password **before** switching the app back:

1. Turn `mysql_entra_stage_aad_only_enabled` off first. This deletes the configuration resource, which resets
   `aad_auth_only` to its server default (`OFF`).
2. Turn `mysql_entra_stage_drop_password_enabled` off. `DATABASE_PASSWORD` returns to the production app, from
   the Key Vault secret that was never removed.
3. Turn `mysql_entra_stage_app_switch_enabled` off. The app is back on `DATABASE_USERNAME=wpadmin` and the
   password, which now exists again.
4. Turn `mysql_entra_stage_identity_enabled` off to remove the administrator, the server identity and the app
   identity attachment.

The flags enforce this order: switching a lower stage off while a higher one is on fails at plan. The MySQL
users you created stay; drop them yourself when you no longer need them.

## Staging Deployment Slots

On Standard (S\*) and Premium (P\*) SKUs the module creates a `staging` deployment slot with its own managed
identity, a Key Vault access policy for that identity, and, when `staging_slot_diagnostic_settings` is set, a
diagnostic setting on the slot. Basic (B\*) plans have no slots, so none of these exist there. In shared-plan
mode the SKU that decides this is `shared_plan_sku`.

`app_service.staging_slot_enabled` (default `true`) opts out of the slot on a SKU that supports one:

```hcl
module "wordpress" {
  # ... existing configuration ...

  app_service = {
    sku_name             = "S1"
    staging_slot_enabled = false # no staging slot, although S1 supports one
  }
}
```

The default keeps the behaviour of every earlier release: a plan that leaves the flag unset is unchanged.
Setting it to `false` on an existing deployment **destroys** the staging slot and its managed identity, the
slot's Key Vault access policy (`azurerm_key_vault_access_policy.staging_slot`) and every slot diagnostic
setting (`azurerm_monitor_diagnostic_setting.staging_slot`). Whatever is deployed to the slot is lost, so swap
it into production first if you want to keep it. A `staging_slot_diagnostic_settings` entry left in place is
ignored, with the same warning as on a B\* SKU. A CanNotDelete lock blocks these deletes; remove it first (see
[Resource locks](#resource-locks)). Setting the flag back to `true` creates a new slot with a new managed
identity, so the slot's principal ID changes.

The `staging_slot_enabled` output says, at plan time, whether the slot exists. `staging_slot_hostname` and
`staging_slot_principal_id` are `null` when it does not; do not drive a `count` from either of them.

## Backup & Recovery

Three mechanisms cover a site, and only the first covers the database:

- **MySQL point-in-time restore.** The Flexible Server keeps its own backups (`database.backup_retention_days`,
  `database.geo_redundant_backup`; see the repository README). No App Service backup includes the database:
  custom backups cannot link a Flexible Server, and this module does not try. Restore the database with
  point-in-time restore, to the same moment as the file restore.
- **App Service automatic backups** exist on every Basic, Standard and Premium app with no configuration:
  hourly, kept 30 days on the platform, up to 30 GB, restorable from the app's Backups page. They cannot be
  downloaded or filtered, and they live in the app's own datacenter.
- **App Service custom backups**, which `app_service_backup_enabled` schedules. Each is a complete copy of the
  app's `/home` (WordPress core, themes, plugins and `wp-content/uploads`) and its configuration, written as a
  zip plus an xml manifest to a private container in the site's storage account, on your schedule, with your
  retention, downloadable as blobs. A custom backup is capped at **10 GB** and fails above it.

### Scheduling a custom backup

```hcl
module "wordpress" {
  # ... existing configuration ...

  storage = {
    additional_containers = { "wp-backups" = {} } # private, the default access_type
  }

  app_service_backup_enabled = true
  app_service_backup = {
    container_name           = "wp-backups" # the default
    frequency_interval       = 1
    frequency_unit           = "Day" # or "Hour", with an interval of at least 2
    retention_period_days    = 30    # 0 to 30; 0 keeps backups indefinitely
    keep_at_least_one_backup = true
    # start_time = "2026-11-01T02:00:00Z" # RFC 3339; unset, the schedule starts when it is configured
  }
}
```

The backup is configured on the production app only; the staging slot is never backed up (on a Basic plan
Azure backs up the production slot only in any case). The target container must be declared in
`storage.additional_containers` with `access_type = "private"` (the default): the module checks this at plan
time and does not create the container itself, so turning the backup off later leaves the backups in place.
Retention is 0 to 30 days (0 keeps backups indefinitely); App Service accepts nothing longer, so the module
rejects it at plan time rather than at apply. For longer retention, keep `0` and let the
[lifecycle rule](#scheduling-a-custom-backup) stay off, or copy backups elsewhere.
App Service allows one custom backup every 2 hours at most (12 a day), so `frequency_unit = "Hour"` needs
`frequency_interval >= 2`; the module rejects a smaller interval at plan time. Enabling the backup on an
existing site is an in-place update of the web app and its slot: the `backup` block and
`virtual_network_backup_restore_enabled` are added, nothing is replaced.

With the backup on, the module sets `virtual_network_backup_restore_enabled` on the app and, when one exists,
on the staging slot (Azure sets it per slot, and a restore into the slot needs it; the slot still has no backup
schedule), so backups and restores travel over the VNet integration. The storage account already allow-lists
the App Service subnet, so `storage_network_rules_default_action` can stay `"Deny"`. Enable the backup, confirm
the first one succeeded, then switch the account to `Deny` if it is not there already.

The storage account is the backup target, and media stays on the app's `/home` storage unless you install a Blob
offload plugin yourself (the module installs none). `"Deny"`, the default, is therefore viable whenever no
browser reads the blob endpoint: the backup travels over the VNet integration and the app subnet is allow-listed.
Only a plugin that points media URLs at the blob endpoint makes browsers fetch from Azure directly, and meet the
firewall; see the storage module's [Network Rules](../storage/README.md#network-rules). Without such a
plugin, setting `app_service_storage_plugin_app_settings_enabled` and `storage_key_secret_enabled` to `false`
takes the account key out of the app's environment and stops the module writing it to the vault.

While `retention_period_days` is finite, the module also adds a second rule to the storage account's lifecycle
management policy, scoped to the backup container: with blob versioning on (`storage.versioning_enabled`, the
default), a backup App Service deletes at the end of its retention survives as a previous version that nothing
would otherwise reclaim, so the rule deletes previous versions and snapshots in that container after the same
number of days. Base blobs are left to App Service. The uploads rule is unchanged, and the policy exists while
this rule is wanted even with `storage.lifecycle_policy_enabled = false`.

### The 10 GB limit and `_backup.filter`

A custom backup fails above 10 GB, so measure what `/home` holds before scheduling one (the Kudu console at
`https://<app>.scm.azurewebsites.net` shows it). To exclude paths, put a `_backup.filter` file in
`/home/site/wwwroot`, one path per line relative to `/home` (Microsoft's example is `\site\wwwroot\Images\2014`).
Microsoft documents the file with Windows-style paths only; excluding paths on a Linux app is unproven here, so
test it on a nonprod site and confirm from the backup's xml manifest. `_backup.filter` also changes restores:
content it lists is left in place instead of being deleted. Logs and caches are the usual exclusions.

### Restoring

Restores go to a **new app or a new slot**, or overwrite an existing one, from the app's Backups page or with
`az webapp config backup restore`; the target is stopped while it runs, so restore to a new slot and swap to
minimise downtime. A restore carries the files and, optionally, the app settings, but not VNet integration,
managed identities, TLS bindings or the backup configuration (custom domains listed in the backup's manifest
are bound only where DNS allows). Two consequences:

- Under `storage_network_rules_default_action = "Deny"`, a new app restoring from the account needs its own
  route to it: allow-list its subnet with `storage_network_rules_virtual_network_subnet_ids`, add an IP rule, or
  set `"Allow"` for the duration of the restore.
- A new app has a new managed identity, so its Key Vault references do not resolve until that identity has an
  access policy on the vault. Restoring into this module's own app, or into its staging slot, keeps everything
  the module manages.

### The SAS: source, rotation and trade-off

App Service authorises a custom backup with a SAS URL only; managed identity is not supported for backup and
restore. The module generates the SAS rather than taking one as input, so no secret crosses the module boundary
and rotation is Terraform's job, not an operator's. `data.azurerm_storage_account_blob_container_sas` signs a
service SAS for the one container with the account key from the storage module's connection string, over
HTTPS only, with read, write, delete and list permissions: the set Microsoft's own backup sample grants, so
check the first backup, which is what proves them. The SAS sits in the app's backup configuration and in
state, both sensitive, and never in an output.

Its validity window comes from `time` resources, never from `timestamp()`, so the SAS is stable between
rotations: a `time_rotating` rotation timestamp, a start 15 minutes before it (`time_offset`, as Microsoft's
SAS guidance asks, so clock skew cannot make a fresh SAS invalid) and an expiry `sas_validity_days` after it
(`time_offset`). By default it is valid for `sas_validity_days = 365` and re-issued by the first plan after
`sas_rotation_days = 180`; validity must be at least twice the rotation interval, so the SAS a rotation
replaces keeps working for at least one more interval while the rotation waits to be applied. A rotation shows
in a plan as a replacement of `time_rotating.backup_sas[0]`, `time_offset.backup_sas_start[0]` and
`time_offset.backup_sas_expiry[0]` and an in-place update of the web app's backup block. `app_service_backup_sas_rotation_rfc3339` and `app_service_backup_sas_expiry_rfc3339` are
outputs, because the dates are not secret, so a scheduled plan-only run can warn well before the SAS expires.

The trade-offs of this source: the SAS is derived from the account key, so rotating the key invalidates it
until the next apply re-issues it (the plan shows the change); the storage account's 7-day `sas_policy` logs
the longer SAS but does not reject it; and anyone who can read state can read the SAS, as with every other
secret there.

**Where the read happens.** The data source lives in this module's root, in `backup.tf`, with no
`depends_on`, like the deployer read in `main.tf`: a data source inside the storage or app-service module
would be deferred to apply time whenever any of that module's `depends_on` targets had a pending change. Here
Terraform reads it at plan time whenever its arguments are known: after the first apply, every plan reads it
unless the storage account itself is being created or replaced, or the SAS is rotating. On the very first plan
the account does not exist yet, so the read waits for apply and the app's `storage_account_url` is known after
apply, that once. A deferred read is noise, not damage: the URL feeds no identity or ForceNew argument, so the
app plans an in-place update, never a replacement. A `depends_on` on the caller's own call to this module
defers the read on every plan, which is one more reason not to add one.

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
- **Staging slot.** Only S* and P* SKUs have a slot, and `app_service.staging_slot_enabled = false` removes
  it. Without a slot the input is ignored and the plan prints a warning.
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
- removing the staging slot (moving from S*/P* to B*, or `app_service.staging_slot_enabled = false`), a web
  test, an alert, or a diagnostic-setting map entry, and turning an alert family back to `enabled = false`;
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
| [azurerm_mysql_flexible_server_configuration.aad_auth_only](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/mysql_flexible_server_configuration) | resource |
| [azurerm_resource_group.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [random_password.db](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [time_offset.backup_sas_expiry](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/offset) | resource |
| [time_offset.backup_sas_start](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/offset) | resource |
| [time_rotating.backup_sas](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/rotating) | resource |
| [time_sleep.dns_propagation](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [azurerm_client_config.current](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/client_config) | data source |
| [azurerm_storage_account_blob_container_sas.backup](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/storage_account_blob_container_sas) | data source |
| [cloudflare_ip_ranges.current](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/data-sources/ip_ranges) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_alert_recipients"></a> [alert\_recipients](#input\_alert\_recipients) | Email addresses for alert notifications | `list(string)` | `[]` | no |
| <a name="input_app_service"></a> [app\_service](#input\_app\_service) | App Service configuration. staging\_slot\_enabled (default true) creates the staging slot on S* and P* SKUs; false creates none, and on an existing deployment destroys the slot, its Key Vault access policy and any staging\_slot\_diagnostic\_settings entry. | <pre>object({<br/>    plan_id                        = optional(string, null)<br/>    use_shared_plan                = optional(bool, false)<br/>    sku_name                       = optional(string, "P1v3")<br/>    always_on                      = optional(bool, true)<br/>    health_check_path              = optional(string)<br/>    worker_count                   = optional(number, 1)<br/>    extra_app_settings             = optional(map(string), {})<br/>    extra_sticky_app_setting_names = optional(list(string), [])<br/>    sticky_connection_string_names = optional(list(string), [])<br/>    staging_app_settings_override  = optional(map(string), {})<br/>    staging_always_on              = optional(bool, false)<br/>    staging_slot_enabled           = optional(bool, true)<br/>    cdn_origin_header_name         = optional(string)<br/>  })</pre> | `{}` | no |
| <a name="input_app_service_backup"></a> [app\_service\_backup](#input\_app\_service\_backup) | Settings of the scheduled App Service backup that app\_service\_backup\_enabled turns on. container\_name (default wp-backups) is the target, which must be a private entry of storage.additional\_containers; while retention\_period\_days is finite, the account's lifecycle policy also expires that container's previous versions and snapshots after the same number of days. frequency\_interval and frequency\_unit (Day, or Hour with an interval of at least 2: App Service allows one custom backup every 2 hours at most), retention\_period\_days (0 to 30; 0 keeps backups indefinitely, and App Service accepts nothing above 30), keep\_at\_least\_one\_backup and start\_time (RFC 3339; null starts the schedule when it is configured) map to the web app's backup block. sas\_validity\_days and sas\_rotation\_days shape the container SAS the module generates: it starts 15 minutes before the rotation timestamp, is valid for sas\_validity\_days from that timestamp, and is re-issued by the first plan after sas\_rotation\_days, so validity must be at least twice the rotation interval (the defaults are a year and six months). | <pre>object({<br/>    container_name           = optional(string, "wp-backups")<br/>    frequency_interval       = optional(number, 1)<br/>    frequency_unit           = optional(string, "Day")<br/>    retention_period_days    = optional(number, 30)<br/>    keep_at_least_one_backup = optional(bool, true)<br/>    start_time               = optional(string)<br/>    sas_validity_days        = optional(number, 365)<br/>    sas_rotation_days        = optional(number, 180)<br/>  })</pre> | `{}` | no |
| <a name="input_app_service_backup_enabled"></a> [app\_service\_backup\_enabled](#input\_app\_service\_backup\_enabled) | Schedule a custom App Service backup of the production app, never the staging slot, to a private container in the site's storage account. Off by default. The module generates the container SAS itself and rotates it on the cadence app\_service\_backup sets; the SAS is never an output. Also sets virtual\_network\_backup\_restore\_enabled on the app, so the backup travels over the VNet integration and the account can keep storage\_network\_rules\_default\_action = "Deny". The target container must be declared in storage.additional\_containers with access\_type "private". See the README's Backup & Recovery section: the 10 GB limit, restores, and that the database is not included. | `bool` | `false` | no |
| <a name="input_app_service_ftp_publish_basic_authentication_enabled"></a> [app\_service\_ftp\_publish\_basic\_authentication\_enabled](#input\_app\_service\_ftp\_publish\_basic\_authentication\_enabled) | Enable basic authentication for FTP publishing on the site and its staging slot. Defaults to true, matching the azurerm provider default. FTP is already closed at the transport layer (ftps\_state is Disabled). | `bool` | `true` | no |
| <a name="input_app_service_ip_security_audit_logs_enabled"></a> [app\_service\_ip\_security\_audit\_logs\_enabled](#input\_app\_service\_ip\_security\_audit\_logs\_enabled) | Send AppServiceIPSecAuditLogs to the site's Log Analytics workspace. Off by default. | `bool` | `false` | no |
| <a name="input_app_service_scm_ip_restriction_default_action"></a> [app\_service\_scm\_ip\_restriction\_default\_action](#input\_app\_service\_scm\_ip\_restriction\_default\_action) | Default action for SCM/Kudu traffic matching no app\_service\_scm\_ip\_restrictions entry. Defaults to 'Allow', matching the azurerm provider default. Set to 'Deny' to close Kudu to everything not allow-listed. | `string` | `"Allow"` | no |
| <a name="input_app_service_scm_ip_restrictions"></a> [app\_service\_scm\_ip\_restrictions](#input\_app\_service\_scm\_ip\_restrictions) | Allow-list for the App Service SCM/Kudu endpoint, applied to both the site and its staging slot. Exactly one of ip\_address, service\_tag or virtual\_network\_subnet\_id must be set per entry. Empty (the default) preserves current provider behaviour. | <pre>list(object({<br/>    ip_address                = optional(string)<br/>    service_tag               = optional(string)<br/>    virtual_network_subnet_id = optional(string)<br/>    name                      = optional(string)<br/>    priority                  = optional(number)<br/>    action                    = optional(string, "Allow")<br/>    description               = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_app_service_storage_plugin_app_settings_enabled"></a> [app\_service\_storage\_plugin\_app\_settings\_enabled](#input\_app\_service\_storage\_plugin\_app\_settings\_enabled) | Set the MICROSOFT\_AZURE\_ACCOUNT\_NAME, MICROSOFT\_AZURE\_CONTAINER and MICROSOFT\_AZURE\_ACCOUNT\_KEY app settings on the site and its staging slot. They exist so an operator can install and configure a Blob offload plugin (the Microsoft Azure Storage for WordPress plugin reads them as wp-config.php constants); they are optional. Defaults to true, which keeps the behaviour of every earlier release. The module installs no plugin and the container image does not read them, so without one they are inert and media stays on /home. False removes them, including the storage account key from the app's environment. The storage-key Key Vault secret is unaffected; set storage\_key\_secret\_enabled = false as well to stop writing it. | `bool` | `true` | no |
| <a name="input_app_service_webdeploy_publish_basic_authentication_enabled"></a> [app\_service\_webdeploy\_publish\_basic\_authentication\_enabled](#input\_app\_service\_webdeploy\_publish\_basic\_authentication\_enabled) | Enable basic authentication for WebDeploy/SCM publishing on the site and its staging slot. Defaults to true, matching the azurerm provider default. Disabling this stops FTP/S deployment from working, but does not change the FTP policy itself - ARM models the two as independent resources, so set app\_service\_ftp\_publish\_basic\_authentication\_enabled = false too. | `bool` | `true` | no |
| <a name="input_availability_tests"></a> [availability\_tests](#input\_availability\_tests) | Standard availability tests against the site's Application Insights component, one per map entry; each gets one metric alert that fires when failed\_location\_count or more locations fail. Empty (the default) creates nothing. url defaults to https://<custom\_domain><path>, so tests probe the public site through the CDN. Requires alert\_recipients or extra\_action\_group\_ids. Each test is billed per execution; see the README before adding locations or raising the frequency. | <pre>map(object({<br/>    url                              = optional(string)      # null => "https://<custom_domain><path>"<br/>    path                             = optional(string, "/") # used only when url is null<br/>    http_verb                        = optional(string, "GET")<br/>    headers                          = optional(map(string), {}) # Host and User-Agent are reserved by the service<br/>    expected_status_code             = optional(number, 200)<br/>    content_match                    = optional(string) # the test passes only if this text is found<br/>    content_match_ignore_case        = optional(bool, false)<br/>    ssl_check_enabled                = optional(bool)        # null => true when the URL is https<br/>    ssl_cert_remaining_lifetime      = optional(number)      # days, 1-365; needs an https URL and the SSL check<br/>    frequency                        = optional(number, 300) # seconds: 300, 600 or 900<br/>    timeout                          = optional(number, 30)  # seconds: 30, 60, 90 or 120<br/>    geo_locations                    = optional(list(string), ["emea-ru-msa-edge", "emea-se-sto-edge", "emea-nl-ams-azr", "emea-gb-db3-azr", "emea-fr-pra-edge"])<br/>    failed_location_count            = optional(number) # null => max(1, locations - 2)<br/>    follow_redirects_enabled         = optional(bool, true)<br/>    parse_dependent_requests_enabled = optional(bool, false) # true also fetches media, which a deny-by-default blob endpoint refuses<br/>    retry_enabled                    = optional(bool, true)<br/>    enabled                          = optional(bool, true)<br/>    alert_severity                   = optional(number, 1)<br/>    description                      = optional(string)<br/>  }))</pre> | `{}` | no |
| <a name="input_cdn_origin_header_values"></a> [cdn\_origin\_header\_values](#input\_cdn\_origin\_header\_values) | Values accepted in the optional CDN origin header. Supply 1 to 8 values when app\_service.cdn\_origin\_header\_name is set. Treat them as bearer secrets. | `list(string)` | `[]` | no |
| <a name="input_cdn_provider"></a> [cdn\_provider](#input\_cdn\_provider) | CDN provider: 'cloudflare' (uses Cloudflare CDN/WAF), 'azure\_front\_door' (uses Azure Front Door), 'direct' (no CDN) | `string` | `"direct"` | no |
| <a name="input_cloudflare"></a> [cloudflare](#input\_cloudflare) | Cloudflare configuration | <pre>object({<br/>    enabled                        = optional(bool, false)<br/>    account_id                     = optional(string, "")<br/>    domain                         = optional(string, "")<br/>    subdomain                      = optional(string, "")<br/>    proxied                        = optional(bool, true)<br/>    enable_waf                     = optional(bool, false) # Needs Business or higher: the login rate-limit rule matches the request method<br/>    enable_page_rules              = optional(bool, true)  # Free plan: 3 rules (wp-admin bypass, wp-login bypass, wp-content cache)<br/>    enable_cache_rules             = optional(bool, false) # Works on Free: 5 of the 10 cache rules it allows<br/>    enable_zone_setting_overrides  = optional(bool, false) # Some settings can't be modified on Free plan<br/>    enable_wordpress_optimizations = optional(bool, true)<br/>  })</pre> | `{}` | no |
| <a name="input_custom_domain"></a> [custom\_domain](#input\_custom\_domain) | Custom domain for the WordPress site | `string` | n/a | yes |
| <a name="input_database"></a> [database](#input\_database) | Database configuration. sku\_name, backup\_retention\_days and geo\_redundant\_backup default by environment when unset - see Environment-aware Defaults in the repository README. NOTE: geo\_redundant\_backup forces replacement of the MySQL server, so set it explicitly on an existing deployment before upgrading. mysql\_version defaults to 8.0.21; changing it on an existing server is an irreversible major-version upgrade (take an on-demand backup and follow Microsoft's major version upgrade guide first). slow\_query\_log\_enabled (default false) sets the slow\_query\_log and long\_query\_time server parameters (long\_query\_time defaults to 2 seconds), so the MySqlSlowLogs category of the MySQL diagnostic setting carries rows. | <pre>object({<br/>    sku_name                  = optional(string)<br/>    storage_size_gb           = optional(number, 100)<br/>    storage_iops              = optional(number, 700)<br/>    backup_retention_days     = optional(number)<br/>    geo_redundant_backup      = optional(bool)<br/>    high_availability_mode    = optional(string, "Disabled")<br/>    storage_auto_grow_enabled = optional(bool, true)<br/>    # Constant default, not environment-aware. See mysql_version in modules/database.<br/>    mysql_version = optional(string, "8.0.21")<br/>    # Opt-in slow query log; constant defaults. Audit logging is not offered.<br/>    slow_query_log_enabled = optional(bool, false)<br/>    long_query_time        = optional(number, 2)<br/>  })</pre> | `{}` | no |
| <a name="input_deployer_object_id"></a> [deployer\_object\_id](#input\_deployer\_object\_id) | Object ID of the principal that runs terraform apply; it gets the Terraform secret-management access policy on the site's Key Vault. Null (the default) keeps the module's own azurerm\_client\_config read. Set it, together with deployer\_tenant\_id, only when plan and apply run as different identities or when the caller needs its own depends\_on on this module; pass a lowercase value known at plan time. The policy's object\_id forces replacement, so a value that differs from the principal that created the existing policy replaces it: do that only as a planned identity cutover. | `string` | `null` | no |
| <a name="input_deployer_tenant_id"></a> [deployer\_tenant\_id](#input\_deployer\_tenant\_id) | Tenant ID of the principal that runs terraform apply, used on its Key Vault access policy. Null (the default) keeps the module's own azurerm\_client\_config read. Set it together with deployer\_object\_id, as a lowercase value. | `string` | `null` | no |
| <a name="input_enable_resource_lock"></a> [enable\_resource\_lock](#input\_enable\_resource\_lock) | Put a CanNotDelete lock (site-protection-lock) on the site resource group. Superseded by lock, and kept: true is equivalent to lock = { kind = "CanNotDelete" }, so switching plans no change. Do not set both. Needs Microsoft.Authorization/locks/* (Owner or User Access Administrator; Contributor lacks it). See the README's Resource locks section before enabling. | `bool` | `false` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name (nonprod or production) | `string` | n/a | yes |
| <a name="input_extra_action_group_ids"></a> [extra\_action\_group\_ids](#input\_extra\_action\_group\_ids) | Additional action group resource IDs that every alert in this module notifies, alongside the site action group (which exists only when alert\_recipients is non-empty). Use it to attach a platform-level group. Empty (the default) changes nothing. With no alert\_recipients, setting it still creates the three baseline alerts (HTTP 5xx, CPU, response time), routed to these groups only. | `list(string)` | `[]` | no |
| <a name="input_extra_secret_app_settings"></a> [extra\_secret\_app\_settings](#input\_extra\_secret\_app\_settings) | Map of App Service app setting name => secret name in the site's Key Vault. Each entry is rendered as @Microsoft.KeyVault(SecretUri=...) and applied to both the production app and the staging slot. Takes precedence over app\_service.extra\_app\_settings on key collision. | `map(string)` | `{}` | no |
| <a name="input_extra_secrets"></a> [extra\_secrets](#input\_extra\_secrets) | Additional secrets to store in the site's Key Vault, as secret name => value. Module-owned names (db-password, appinsights-connection, and storage-key unless storage\_key\_secret\_enabled is false) take precedence and cannot be overridden. Keys must be known at plan time. | `map(string)` | `{}` | no |
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
| <a name="input_mysql_entra_admin"></a> [mysql\_entra\_admin](#input\_mysql\_entra\_admin) | The MySQL server's Microsoft Entra administrator: login (the MySQL user name, at most 32 characters), object\_id and tenant\_id. Used from stage 1. The module passes object\_id to the provider exactly as given and does not translate it. The azurerm documentation says that for a managed identity it should be the identity's client ID; the design rehearsal on a real server set the administrator by the identity's principal (object) ID and it worked. Confirm on the first stage-1 apply on a non-production server, and use the value that proves out for you. Layout B is the administrator and the app being the same identity: object\_id equal to mysql\_entra\_app\_identity.principal\_id when the principal ID is the proven value, or mysql\_entra\_app\_identity.client\_id when the client ID is, with mysql\_entra\_app\_database\_user equal to login. Layout A uses different values. Null (the default) means unused. | <pre>object({<br/>    login     = string<br/>    object_id = string<br/>    tenant_id = string<br/>  })</pre> | `null` | no |
| <a name="input_mysql_entra_admin_wait_seconds"></a> [mysql\_entra\_admin\_wait\_seconds](#input\_mysql\_entra\_admin\_wait\_seconds) | Seconds to wait between attaching the server identity and creating the Entra administrator at stage 1, because a freshly attached identity can still be propagating and the API then fails transiently. Applies only while mysql\_entra\_stage\_identity\_enabled is true, and once, when the administrator is first created. 0 skips the wait. The default is 30. | `number` | `30` | no |
| <a name="input_mysql_entra_app_database_user"></a> [mysql\_entra\_app\_database\_user](#input\_mysql\_entra\_app\_database\_user) | The MySQL user the app logs in as: its DATABASE\_USERNAME from stage 2, at most 32 characters. The caller creates it (CREATE AADUSER) unless it is the administrator's login. Null (the default) means unused. | `string` | `null` | no |
| <a name="input_mysql_entra_app_identity"></a> [mysql\_entra\_app\_identity](#input\_mysql\_entra\_app\_identity) | The user-assigned identity the WordPress app uses to log in to MySQL: id (resource ID), client\_id and principal\_id. Created by the caller. Used from stage 1, where it is attached to the production app only, never the staging slot, which makes that app SystemAssigned, UserAssigned; the system-assigned identity stays and keeps resolving Key Vault references. From stage 2 its client\_id is the app's ENTRA\_CLIENT\_ID setting. The deploying principal needs Managed Identity Operator on it. Null (the default) means unused. | <pre>object({<br/>    id           = string<br/>    client_id    = string<br/>    principal_id = string<br/>  })</pre> | `null` | no |
| <a name="input_mysql_entra_server_identity"></a> [mysql\_entra\_server\_identity](#input\_mysql\_entra\_server\_identity) | The user-assigned identity the MySQL server uses to validate Microsoft Entra tokens: id (resource ID), client\_id and principal\_id. Created by the caller. Used from stage 1 (mysql\_entra\_stage\_identity\_enabled), where it is attached to the server and named as the administrator resource's identity\_id; only id is read. Layout A (a separate server identity, an administrator that is a person or a group, and the app mapped to a non-admin MySQL user) needs the Microsoft Graph application permissions User.Read.All, GroupMember.Read.All and Application.Read.All granted to this identity by the caller. Layout B (the administrator is the app's own identity) needs no Graph permission. Null (the default) means unused. | <pre>object({<br/>    id           = string<br/>    client_id    = string<br/>    principal_id = string<br/>  })</pre> | `null` | no |
| <a name="input_mysql_entra_stage_aad_only_enabled"></a> [mysql\_entra\_stage\_aad\_only\_enabled](#input\_mysql\_entra\_stage\_aad\_only\_enabled) | Stage 4, off by default; requires mysql\_entra\_stage\_drop\_password\_enabled. Sets the aad\_auth\_only server parameter to ON, so only Microsoft Entra logins work and the password administrator can no longer connect. It is applied after the app update, so enabling stages 2 to 4 in one apply switches the app first. Fails at plan while a staging slot exists, because the slot still logs in with a password: set app\_service.staging\_slot\_enabled = false first (the slot is then destroyed). Turn it off first when rolling back; that deletes the parameter's configuration resource, which resets it to OFF. | `bool` | `false` | no |
| <a name="input_mysql_entra_stage_app_switch_enabled"></a> [mysql\_entra\_stage\_app\_switch\_enabled](#input\_mysql\_entra\_stage\_app\_switch\_enabled) | Stage 2, off by default; requires mysql\_entra\_stage\_identity\_enabled and mysql\_entra\_app\_database\_user. Sets ENABLE\_MYSQL\_MANAGED\_IDENTITY=true, ENTRA\_CLIENT\_ID and DATABASE\_USERNAME on the production app, so the image logs in with a token. The container restarts; on the Microsoft image that was measured with no failed request. With a staging slot, those names, and DATABASE\_PASSWORD, become sticky and the slot keeps its password settings. Rejects app\_service.extra\_app\_settings and extra\_secret\_app\_settings that set CACHE\_MYSQL\_ACCESS\_TOKEN=true (the token cache starts a PHP session on every request and writes the token to a file) or DB\_SSL\_CONNECTION=false (TLS off), and any that name ENABLE\_MYSQL\_MANAGED\_IDENTITY, ENTRA\_CLIENT\_ID or DATABASE\_USERNAME, which would override the staged value. Before turning it on, check that the site's wp-config.php carries the image's managed-identity block (see the README). To go back, switch stages 4 and 3 off first, then this one: the app needs its password setting back before the username does. | `bool` | `false` | no |
| <a name="input_mysql_entra_stage_drop_password_enabled"></a> [mysql\_entra\_stage\_drop\_password\_enabled](#input\_mysql\_entra\_stage\_drop\_password\_enabled) | Stage 3, off by default; requires mysql\_entra\_stage\_app\_switch\_enabled. Removes DATABASE\_PASSWORD from the production app, and rejects extra settings that name DATABASE\_PASSWORD, which would put it back. The db-password Key Vault secret is still written, because the way back needs it, and the staging slot keeps its DATABASE\_PASSWORD. Turn it off again, and apply, before turning stage 2 off. | `bool` | `false` | no |
| <a name="input_mysql_entra_stage_identity_enabled"></a> [mysql\_entra\_stage\_identity\_enabled](#input\_mysql\_entra\_stage\_identity\_enabled) | Stage 1 of the passwordless database path, off by default. Attaches mysql\_entra\_server\_identity to the MySQL server, sets mysql\_entra\_admin as its Microsoft Entra administrator, and attaches mysql\_entra\_app\_identity to the production app (SystemAssigned, UserAssigned). No app setting changes, so the app keeps using its password. Requires the three inputs. None of it replaces the server or the app, and turning it off removes the identity and the administrator again. | `bool` | `false` | no |
| <a name="input_mysql_require_secure_transport"></a> [mysql\_require\_secure\_transport](#input\_mysql\_require\_secure\_transport) | Set the MySQL require\_secure\_transport server parameter to ON, so the server refuses connections made without TLS, token logins included. The default, false, keeps the OFF every earlier release set. PHP connects with TLS by default (DB\_SSL\_CONNECTION defaults to true) but the image does not verify the server certificate, so this closes the plain-text path without adding verification. Not one of the four stages; it applies at once and refuses any client that does not use TLS, so check the app and any other client first. | `bool` | `false` | no |
| <a name="input_networking"></a> [networking](#input\_networking) | Networking configuration | <pre>object({<br/>    vnet_address_space           = optional(string, "10.0.0.0/16")<br/>    app_subnet_cidr              = optional(string, "10.0.0.0/24")<br/>    db_subnet_cidr               = optional(string, "10.0.1.0/24")<br/>    private_endpoint_subnet_cidr = optional(string, "10.0.2.0/24")<br/>  })</pre> | `{}` | no |
| <a name="input_plan_density_limit"></a> [plan\_density\_limit](#input\_plan\_density\_limit) | DEPRECATED, and has no effect: nothing in this module reads it, so it enforces no limit on sites per App Service Plan. It is kept, with its validation, only so existing configurations that set it still plan, and will be removed in the next major release. Remove it from your configuration. | `number` | `10` | no |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name used in resource naming (lowercase, 2-24 chars) | `string` | n/a | yes |
| <a name="input_shared_plan_sku"></a> [shared\_plan\_sku](#input\_shared\_plan\_sku) | SKU of the shared App Service Plan. Required when app\_service.use\_shared\_plan = true to determine feature availability. | `string` | `null` | no |
| <a name="input_shared_resource_group_name"></a> [shared\_resource\_group\_name](#input\_shared\_resource\_group\_name) | Name of the shared resource group where the shared App Service Plan is located. Required when app\_service.use\_shared\_plan = true. | `string` | `null` | no |
| <a name="input_site_name"></a> [site\_name](#input\_site\_name) | Site name used for resource naming (lowercase, hyphens only) | `string` | n/a | yes |
| <a name="input_staging_slot_diagnostic_settings"></a> [staging\_slot\_diagnostic\_settings](#input\_staging\_slot\_diagnostic\_settings) | Diagnostic settings for the staging slot, AVM diagnostic\_settings shape, one setting per map entry. Empty (the default) creates none. Only S* and P* SKUs have a slot; on any other SKU, or when app\_service.staging\_slot\_enabled is false, this input is ignored, with a warning. logs = null sends the four App Service categories the production app sends; metrics = null sends AllMetrics. With no destination set, it sends to the site workspace. | <pre>map(object({<br/>    name = optional(string, null) # null => diag-<target>-<site_name>-<map key><br/>    logs = optional(set(object({  # null => the target's default categories<br/>      category       = optional(string, null)<br/>      category_group = optional(string, null)<br/>      enabled        = optional(bool, true) # false entries are dropped<br/>    })))<br/>    metrics = optional(set(object({ # null => the target's default metrics<br/>      category = optional(string, "AllMetrics")<br/>      enabled  = optional(bool, true)<br/>    })))<br/>    log_analytics_destination_type           = optional(string, null) # AVM defaults to "Dedicated"; null leaves Azure's default<br/>    workspace_resource_id                    = optional(string, null) # null, with no other destination => the site workspace<br/>    storage_account_resource_id              = optional(string, null)<br/>    event_hub_authorization_rule_resource_id = optional(string, null)<br/>    event_hub_name                           = optional(string, null)<br/>    marketplace_partner_resource_id          = optional(string, null)<br/>  }))</pre> | `{}` | no |
| <a name="input_storage"></a> [storage](#input\_storage) | Storage account configuration | <pre>object({<br/>    additional_containers           = optional(map(object({ access_type = optional(string, "private") })), {})<br/>    versioning_enabled              = optional(bool, true)<br/>    blob_delete_retention_days      = optional(number, 30)<br/>    container_delete_retention_days = optional(number, 30)<br/>    lifecycle_policy_enabled        = optional(bool, true)<br/>    lifecycle_cool_tier_days        = optional(number, 30)<br/>    lifecycle_version_delete_days   = optional(number, 90)<br/>    lifecycle_snapshot_delete_days  = optional(number, 90)<br/>    lifecycle_prefix_match          = optional(list(string), ["uploads/"])<br/>  })</pre> | `{}` | no |
| <a name="input_storage_blob_diagnostic_settings"></a> [storage\_blob\_diagnostic\_settings](#input\_storage\_blob\_diagnostic\_settings) | Diagnostic settings for the storage account's blob service, AVM diagnostic\_settings shape, one setting per map entry. Empty (the default) creates none. logs = null sends StorageRead, StorageWrite and StorageDelete; metrics = null sends Transaction. AllMetrics is rejected: the API expands it into Capacity and Transaction, which plans a change on every run. With no destination set, it sends to the site workspace. | <pre>map(object({<br/>    name = optional(string, null) # null => diag-<target>-<site_name>-<map key><br/>    logs = optional(set(object({  # null => the target's default categories<br/>      category       = optional(string, null)<br/>      category_group = optional(string, null)<br/>      enabled        = optional(bool, true) # false entries are dropped<br/>    })))<br/>    metrics = optional(set(object({ # null => the target's default metrics<br/>      category = optional(string, "AllMetrics")<br/>      enabled  = optional(bool, true)<br/>    })))<br/>    log_analytics_destination_type           = optional(string, null) # AVM defaults to "Dedicated"; null leaves Azure's default<br/>    workspace_resource_id                    = optional(string, null) # null, with no other destination => the site workspace<br/>    storage_account_resource_id              = optional(string, null)<br/>    event_hub_authorization_rule_resource_id = optional(string, null)<br/>    event_hub_name                           = optional(string, null)<br/>    marketplace_partner_resource_id          = optional(string, null)<br/>  }))</pre> | `{}` | no |
| <a name="input_storage_key_secret_enabled"></a> [storage\_key\_secret\_enabled](#input\_storage\_key\_secret\_enabled) | Write the storage account's primary access key to the site's Key Vault as the storage-key secret. Defaults to true, which keeps the behaviour of every earlier release. The only reader in this module is the MICROSOFT\_AZURE\_ACCOUNT\_KEY app setting, so false requires app\_service\_storage\_plugin\_app\_settings\_enabled = false and fails at plan otherwise. On an existing site, false deletes the secret from the vault (a data-plane delete, which a CanNotDelete lock does not block, so no lock change is needed; whether it stays recoverable depends on the vault's purge protection); nothing else changes. The scheduled App Service backup does not use this secret, and the account's shared-key access setting is unchanged. | `bool` | `true` | no |
| <a name="input_storage_network_rules_bypass"></a> [storage\_network\_rules\_bypass](#input\_storage\_network\_rules\_bypass) | Traffic permitted to bypass the storage network rules. Valid values: AzureServices, Logging, Metrics, None. | `set(string)` | <pre>[<br/>  "AzureServices"<br/>]</pre> | no |
| <a name="input_storage_network_rules_default_action"></a> [storage\_network\_rules\_default\_action](#input\_storage\_network\_rules\_default\_action) | Default action for the storage account's network rules. Defaults to Deny, which suits the default setup: media stays on the app's /home storage and the scheduled backup reaches the account over the app subnet. Set to 'Allow' only if browsers read the blob endpoint directly, for example media from a Blob offload plugin you install, rather than through a CDN custom domain. | `string` | `"Deny"` | no |
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
| <a name="output_app_service_backup_sas_expiry_rfc3339"></a> [app\_service\_backup\_sas\_expiry\_rfc3339](#output\_app\_service\_backup\_sas\_expiry\_rfc3339) | When the current backup container SAS expires. The backup fails after this if no plan has been applied since the rotation date. Null when app\_service\_backup\_enabled is false. |
| <a name="output_app_service_backup_sas_rotation_rfc3339"></a> [app\_service\_backup\_sas\_rotation\_rfc3339](#output\_app\_service\_backup\_sas\_rotation\_rfc3339) | When the backup container SAS is next re-issued: the first plan after this time replaces it, which is the date to act on. Null when app\_service\_backup\_enabled is false. |
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
| <a name="output_mysql_entra_stage"></a> [mysql\_entra\_stage](#output\_mysql\_entra\_stage) | How far the passwordless database path has gone, 0 to 4: 0 none, 1 identity and administrator, 2 app switched to the token login, 3 DATABASE\_PASSWORD dropped from the production app, 4 aad\_auth\_only ON. Known at plan time. The stage flags must be turned on in order, so this is also the number of flags that are on. |
| <a name="output_resource_group_id"></a> [resource\_group\_id](#output\_resource\_group\_id) | ID of the resource group |
| <a name="output_resource_group_name"></a> [resource\_group\_name](#output\_resource\_group\_name) | Name of the resource group |
| <a name="output_site_name"></a> [site\_name](#output\_site\_name) | The site name |
| <a name="output_staging_slot_enabled"></a> [staging\_slot\_enabled](#output\_staging\_slot\_enabled) | Whether the staging slot is created: app\_service.staging\_slot\_enabled is true and the SKU is S* or P*. Known at plan time; staging\_slot\_hostname and staging\_slot\_principal\_id are null when this is false. |
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
