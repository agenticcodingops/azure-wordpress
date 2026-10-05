# MySQL 8.0 to 8.4

## What v4.1.0 records

[`CHANGELOG.md`](../../CHANGELOG.md) and the [v4.1.0 release notes](https://github.com/agenticcodingops/azure-wordpress/releases/tag/v4.1.0) both contain this feature line:

> * **database:** expose the database server version, default unchanged ([#62](https://github.com/agenticcodingops/azure-wordpress/issues/62)) ([24e61b7](https://github.com/agenticcodingops/azure-wordpress/commit/24e61b7be04b92e31941a36ff62ceab6a6e612fc))

Leaving the input unset: the line says the default is unchanged. Neither source states the plan diff. **UNKNOWN.**

Setting another version: neither source states whether the server is updated in place, replaced, or destroyed. **UNKNOWN.**

## Moved note

[Upgrading to v4.1.0](v4.0-to-v4.1.md#upgrading-to-v410) on the 4.0 to 4.1 page is the former site-module section. Its `database.mysql_version` bullet says that setting `"8.4"` on an existing server is an irreversible major-version upgrade, and that a dry run shows whether the provider updates the server in place or replaces it. That bullet is the moved note, not a changelog statement.

## Open issue

The procedure for this upgrade is tracked in [#70](https://github.com/agenticcodingops/azure-wordpress/issues/70). This page links that issue and does not copy its findings. Those findings are not in `CHANGELOG.md` or the release notes.
