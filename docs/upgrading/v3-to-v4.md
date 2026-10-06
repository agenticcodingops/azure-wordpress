# v3 to v4

Two releases sit on this transition. v4.0.0 compares against v3.1.0, so the v3.1.0 note is here as well.

## Expected plan

### v3.1.0

[`CHANGELOG.md`](../../CHANGELOG.md) and the [v3.1.0 release notes](https://github.com/agenticcodingops/azure-wordpress/releases/tag/v3.1.0) record one feature: harden the SCM/Kudu plane, expose basic-auth publishing controls, and re-export `database_server_name`. Neither source states a plan diff, or whether anything is replaced or destroyed. **UNKNOWN.**

The module note moved below states its own plan: no plan diff from the SCM and publishing-credential controls when they are left unset, and one `app_settings` diff plus an app restart from the renamed settings. That is the moved note, not a changelog statement.

### v4.0.0

[`CHANGELOG.md`](../../CHANGELOG.md) and the [v4.0.0 release notes](https://github.com/agenticcodingops/azure-wordpress/releases/tag/v4.0.0) say: "Root modules must require azurerm ~> 5.6. Module inputs are unchanged."

Neither source states the plan diff. **UNKNOWN.** Neither source states that anything is replaced or destroyed.

The release notes repeat that breaking-change bullet and contain a generated summary that restates it. They do not state a plan diff.

The repository README text moved below talks about provider registration and says Key Vault purge protection, soft-delete retention, and MySQL geo-redundant backup are unchanged by this release. Those sentences are not in the changelog or the release notes. From those two sources they are **UNKNOWN.**

## Changelog entries

### v3.1.0

Copied unchanged from [`CHANGELOG.md`](../../CHANGELOG.md).

## [3.1.0](https://github.com/agenticcodingops/azure-wordpress/compare/v3.0.0...v3.1.0) (2026-08-08)


### Features

* harden the SCM/Kudu plane, expose basic-auth publishing controls, re-export database_server_name ([#30](https://github.com/agenticcodingops/azure-wordpress/issues/30)) ([b860e9e](https://github.com/agenticcodingops/azure-wordpress/commit/b860e9e3f31f5692b4f940e4cbbdf5e5fad2b7be))

### v4.0.0

Copied unchanged from [`CHANGELOG.md`](../../CHANGELOG.md).

## [4.0.0](https://github.com/agenticcodingops/azure-wordpress/compare/v3.1.0...v4.0.0) (2026-09-24)


### ⚠ BREAKING CHANGES

* Root modules must require azurerm ~> 5.6. Module inputs are unchanged.

### Features

* move every module to azurerm 5.x ([#49](https://github.com/agenticcodingops/azure-wordpress/issues/49)) ([a231a23](https://github.com/agenticcodingops/azure-wordpress/commit/a231a23a914cd4a181f342b35ad5cab5efa6b973))

## Moved from the site module

The wording below is the former section of `modules/wordpress-site/README.md`. Links that pointed at headings in that file, or at `docs/` from that file, now use a path from this directory.

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
  source = "github.com/agenticcodingops/azure-wordpress//modules/wordpress-site?ref=v4.1.1"

  # ... existing configuration ...

  app_service_scm_ip_restrictions = [
    { ip_address = "203.0.113.10/32", name = "OperatorHome" },
  ]
  app_service_scm_ip_restriction_default_action = "Deny"

  app_service_ftp_publish_basic_authentication_enabled       = false
  app_service_webdeploy_publish_basic_authentication_enabled = false
}
```

**Read [modules/app-service/README.md](../../modules/app-service/README.md#scmkudu-network-posture) before
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

## Moved from the repository README

The wording below is the former "Upgrading from v3 to v4" section of `README.md`.

### Upgrading from v3 to v4

v4.0.0 moves every module onto azurerm `~> 5.6`. The root module must require that same constraint, or `terraform init` cannot resolve a provider. No module inputs change. Run `terraform plan` before the first apply. Key Vault purge protection, soft-delete retention, and MySQL geo-redundant backup are unchanged by this release, and each of them is costly to change after the resource exists.

The provider no longer registers resource providers unless asked: `resource_provider_registrations` defaults to `none`, and `skip_provider_registration` is removed. Set `resource_provider_registrations = "legacy"` to keep the previous automatic set. Plan-time location and resource-provider checks also default off. Set `features.enhanced_validation.locations` and `features.enhanced_validation.resource_providers` to `true` to keep catching those at plan time. The examples set all three.

