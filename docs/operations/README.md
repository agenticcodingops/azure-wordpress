# Operations runbooks

Task-sized procedures for running sites built with this repository's modules. Each runbook says when to use it,
what you need first, the steps with exact commands, how to check the result, and how to back out.

They are generic. Every name, ID and host name is a placeholder such as `<resource-group>`, and a command is shown
only after its flags were checked against the tool's `--help` or documentation. The runbooks describe release
**v4.3.0**. They do not repeat the long-form guides: where a guide already explains something they link to it, and
the long-form guides stay the place for the reasoning.

| Runbook | Use it to |
| --- | --- |
| [Deploy a new site](deploy-a-new-site.md) | Add a site to an existing root configuration, nonprod first |
| [Upgrade the module](upgrade-the-module.md) | Move the `?ref=` pin to a newer release |
| [Rotate secrets](rotate-secrets.md) | Rotate the database password, Key Vault secrets, the storage key, the origin-header values and CDN API tokens |
| [Backup and restore](backup-and-restore.md) | Check what protects a site, take a backup, and restore the database (point-in-time) or the app's files |
| [Image-tag policy](image-tag-policy.md) | Choose a floating or dated image tag and prove which image runs |
| [Alerting](alerting.md) | Turn alerts on, route them, and prove they fire |
| [MySQL major-version upgrade](mysql-major-version-upgrade.md) | Move an existing server from MySQL 8.0 to 8.4 |
| [Troubleshooting](troubleshooting.md) | Diagnose an origin 403, a Key Vault 403, a media 403, a soft-deleted vault, a lock, a deferred read |

## Conventions

- **Environments.** `nonprod` is `np` in resource names and `production` is `prod`. Do a change in nonprod first and
  read its plan before you repeat it in production.
- **Names.** `<resource-group>` is the site's group, `rg-<project_name>-<site_name>-<np|prod>`: it holds the MySQL
  server, Key Vault, storage account, monitoring and alerts, and is the module's `resource_group_name` output.
  `<app-resource-group>` is the group that holds the web app and its staging slot. It is the same group as
  `<resource-group>` on a dedicated plan, but on a shared plan it is the shared group, `rg-<project_name>-shared-<np|prod>`
  (`shared_resource_group_name`), so every `az webapp` command uses it. `<app-name>` is
  `app-<project_name>-<site_name>-<np|prod>` and `<server-name>` is `mysql-<project_name>-<site_name>-<np|prod>`. The
  outputs `resource_group_name`, `app_service_name` and `database_server_name` give the real values; expose them from
  your root configuration if you want `terraform output` to print them.
- **Plans.** Read every plan before you apply it. Where a runbook names what a plan must show, stop if it shows
  more.
- **Secrets.** Never paste a secret into a command line you keep in shell history or a log. Load values from a
  secret store or an environment variable, and treat read access to Terraform state as read access to every secret
  the module generated ([Security model](../security-model.md#terraform-state-holds-generated-secrets)).
- **Locks.** A `CanNotDelete` lock turns any replacement or removal into a failed apply. The runbooks say where
  that matters; see [Troubleshooting](troubleshooting.md#a-resource-lock-blocks-a-change).

## Related guides

- [Getting started](../getting-started.md) and the [deployment guide](../deployment-guide.md): the first
  deployment and the production pipeline.
- [Upgrade guide](../upgrading/README.md): what changed in each release.
- [Architecture](../architecture.md) and the [security model](../security-model.md): how the parts fit and what is
  enforced.
