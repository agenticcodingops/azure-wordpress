# MySQL 8.0 to 8.4

## What v4.1.0 records

[`CHANGELOG.md`](../../CHANGELOG.md) and the [v4.1.0 release notes](https://github.com/agenticcodingops/azure-wordpress/releases/tag/v4.1.0) both contain this feature line:

> * **database:** expose the database server version, default unchanged ([#62](https://github.com/agenticcodingops/azure-wordpress/issues/62)) ([24e61b7](https://github.com/agenticcodingops/azure-wordpress/commit/24e61b7be04b92e31941a36ff62ceab6a6e612fc))

Leaving the input unset: the line says the default is unchanged. Neither source states the plan diff, so it is **UNKNOWN** from the release record alone. The input's own description says the default, `8.0.21`, is the version every existing server was created with, "so leaving it unset changes nothing" (`modules/database/variables.tf`).

Setting another version: neither source states whether the server is updated in place, replaced, or destroyed, so that is **UNKNOWN** from the release record alone. Issue [#70](https://github.com/agenticcodingops/azure-wordpress/issues/70) reports a real plan on azurerm 5.7.0 that updates the version in place (`0 to add, 1 to change, 0 to destroy`): `version` stopped being `ForceNew` in azurerm 4.34.0, and every module here requires `~> 5.6`. That is the issue's finding. The input's description and the [site module README](../../modules/wordpress-site/README.md#upgrading-mysql-80-to-84) now state it, and it is not a changelog statement.

## Moved note

[Upgrading to v4.1.0](v4.0-to-v4.1.md#upgrading-to-v410) on the 4.0 to 4.1 page is the former site-module section. Its `database.mysql_version` bullet says that setting `"8.4"` on an existing server is an irreversible major-version upgrade, and that a dry run shows whether the provider updates the server in place or replaces it. That bullet is the moved note, not a changelog statement.

## Procedure

The procedure for this upgrade is in the [MySQL major-version upgrade runbook](../operations/mysql-major-version-upgrade.md). It rests on the findings in [#70](https://github.com/agenticcodingops/azure-wordpress/issues/70), which this page cites above; they are not in `CHANGELOG.md` or the release notes. The Burstable steps are unmeasured and still need a real run.
