# Alerting

## When to use

You are turning alerts on for a site, changing who receives them, or want proof that they fire. The full list of alert
families, defaults and caveats is in [README, Alerting](../../modules/wordpress-site/README.md#alerting) and
[Availability tests](../../modules/wordpress-site/README.md#availability-tests). This runbook is the procedure around
them.

## What exists

Every alert needs a route: `alert_recipients` (creates the site action group `ag-<project_name>-<site_name>-<np|prod>`
with one email receiver per address) or `extra_action_group_ids`, or both. Turning on an opt-in alert without a route
fails the plan (`modules/wordpress-site/main.tf`).

| Alert rule name | Exists when | Fires when |
| --- | --- | --- |
| `alert-http5xx-<prefix>` | A route exists | `Http5xx` total on the app above `monitoring.alerts.http_5xx_threshold` (10) in `alert_window_minutes` (5) |
| `alert-highcpu-<prefix>` | A route exists | Plan `CpuPercentage` average above `high_cpu_threshold` (80) |
| `alert-responsetime-<prefix>` | A route exists | `HttpResponseTime` average above 3 seconds over PT5M |
| `alert-avail-<test>-<prefix>`, with `webtest-<test>-<prefix>` | `availability_tests` has entries | `failed_location_count` or more locations fail in the same window |
| `alert-mysql-<check>-<prefix>`, where `<check>` is `cpupercent`, `memorypercent`, `storagepercent`, `abortedconnections`, `activeconnections` or `cpucreditsremaining` | `monitoring.alerts.mysql.enabled` | CPU, memory, storage, aborted connections, active connections or CPU credits cross their thresholds |
| `alert-5xxrate-<prefix>` | `monitoring.alerts.http_5xx_rate.enabled` | 5xx responses exceed `threshold_percent` (5) of production requests, with at least `minimum_requests` (20) |
| `alert-healthcheck-<prefix>` | `monitoring.alerts.health_check.enabled` | `HealthCheckStatus` average below 100 over PT15M |
| `alert-resourcehealth-<prefix>` | `monitoring.alerts.resource_health.enabled` | A resource moves into `Degraded` or `Unavailable` for a platform-initiated or unknown cause |

`<prefix>` is `<project_name>-<site_name>-<np|prod>`. Sources: `modules/wordpress-site/main.tf` (the baseline alerts and
the action group) and `modules/wordpress-site/monitoring.tf` (the rest).

Azure also creates a `Failure Anomalies - <component>` rule and an `Application Insights Smart Detection` action group
next to the Application Insights component. Terraform does not manage them, and the rule has nothing to analyse for
PHP without an SDK ([README](../../modules/wordpress-site/README.md#failure-anomalies-platform-created)).

## Prerequisites

- Email addresses (or action group IDs) that people read. An alert nobody receives is the same as no alert.
- For `http_5xx_rate`: a site that already streams `AppServiceHTTPLogs`. On a brand-new site, enable it in a second
  apply, up to about 90 minutes after the app's diagnostic setting is created.
- Removing or disabling an alert later is a delete, which a `CanNotDelete` lock refuses
  ([Troubleshooting](troubleshooting.md#a-resource-lock-blocks-a-change)).

## Steps

1. **Set the route and the families** in the site's configuration:

   ```hcl
   alert_recipients = ["ops@example.com"]

   availability_tests = { home = {} } # https://<custom_domain>/ from five locations

   monitoring = {
     alerts = {
       mysql           = { enabled = true }
       http_5xx_rate   = { enabled = true }
       health_check    = { enabled = true }
       resource_health = { enabled = true }
     }
   }
   ```

   Point an availability test at the public custom domain, not the app's own host name: behind Cloudflare or Front
   Door the origin answers `403` to the test agents.
2. **Plan, apply nonprod, then production.** The plan adds the rules and the action group; it changes nothing else.
3. **List what exists:**

   ```bash
   az monitor metrics alert list --resource-group <resource-group> \
     --query "[].{name:name, enabled:enabled, severity:severity}" -o table
   az monitor activity-log alert list --resource-group <resource-group> -o table
   az resource list --resource-group <resource-group> --resource-type Microsoft.Insights/scheduledQueryRules -o table
   az monitor action-group show --resource-group <resource-group> --name ag-<project_name>-<site_name>-<np|prod> -o json
   ```

   Expect every rule in the table above that your configuration enables, each `enabled`, and the action group's email
   receivers.

## Test that alerts fire

Do this in nonprod. There are two separate things to prove: the route delivers, and a rule evaluates and fires.

### A. The route delivers

Send a test notification through the action group to an address you can read:

```bash
az monitor action-group test-notifications create --resource-group <resource-group> \
  --action-group-name ag-<project_name>-<site_name>-<np|prod> --alert-type metricstaticthreshold \
  --add-action email test-receiver <your-address>
```

The command takes its receivers in the call, so repeat it for each address you rely on. A received email proves the
delivery path to that address. It does not prove any rule.

### B. A rule evaluates and fires

1. **Read the current value** of the metric a baseline rule watches, for the plan's CPU for example (the plan's resource
   ID is the module output `app_service_plan_id`):

   ```bash
   az monitor metrics list --resource <app-service-plan-id> --metrics CpuPercentage \
     --aggregation Average --interval PT5M --offset 1h -o table
   ```

2. **Set a threshold just under it** in the nonprod configuration (`monitoring.alerts.high_cpu_threshold`, or
   `http_5xx_threshold`, or a `mysql` threshold), apply, and wait one evaluation window. The rules evaluate every minute
   (the baseline ones), so the alert fires within about the window plus a few minutes, not instantly.
3. **Confirm it fired:** the email arrives, and Monitor, Alerts in the portal lists a fired alert with the rule's name.
4. **Put the threshold back** and apply. The alert resolves after the metric is under the threshold again.

For the availability alert, stop the nonprod app and wait for the test frequency plus the window:

```bash
az webapp stop --resource-group <app-resource-group> --name <app-name>
# wait, confirm the alert fired, then:
az webapp start --resource-group <app-resource-group> --name <app-name>
```

That also exercises `alert-healthcheck` later than the availability test, because the platform reports a health-check
failure only after an instance is judged unhealthy (10 consecutive failed pings by default) plus the window. Stopping an
app is a user-initiated event, so `alert-resourcehealth` does not fire for it by design. Treat the availability test as
the primary "site down" signal.

Do not change a rule with `az monitor metrics alert update` to test it: Terraform plans the difference away at the next
apply, and a forgotten change hides a real setting.

## Verify

- Each expected rule is `enabled` and its action list names the site action group.
- The delivery test (A) arrived, and a deliberate threshold change (B) produced a fired alert and an email.
- After you revert the threshold, a re-plan reports no changes.
- At least one person outside the team that operates the site has seen a test alert and knows what to do with it.

## Rollback

Revert the configuration change and apply. Removing an alert needs the resource-group lock off for that apply.
`monitoring.alerts.db_failure_threshold` feeds the MySQL `aborted_connections` rule only while `mysql.enabled` is true.

## Sources

`modules/wordpress-site/main.tf` (baseline alerts, `azurerm_monitor_action_group.main`, routing precondition),
`modules/wordpress-site/monitoring.tf`, [README, Alerting](../../modules/wordpress-site/README.md#alerting).
