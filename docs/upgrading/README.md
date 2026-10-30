# Upgrade guide

Latest release: **v4.3.2**. Pin module sources with `?ref=v4.3.2`. Releases are listed on the [Releases](https://github.com/agenticcodingops/azure-wordpress/releases) page.

These pages hold the upgrade notes that were in the repository README, in `modules/wordpress-site/README.md`, and in the changelog's upgrade-path sections. Changelog text is copied unchanged. A statement about what a release changed is cited to [`CHANGELOG.md`](../../CHANGELOG.md) or to that version's [release notes](https://github.com/agenticcodingops/azure-wordpress/releases). Where neither states a plan diff, or whether anything is replaced or destroyed, the page says **UNKNOWN**.

Read every page between the release you are on and the release you are moving to.

| Transition | Page | Releases on the page |
| --- | --- | --- |
| v1 to v2 | [v1 to v2](v1-to-v2.md) | v2.0.0 |
| v2 to v3 | [v2 to v3](v2-to-v3.md) | v3.0.0 |
| v3 to v4 | [v3 to v4](v3-to-v4.md) | v3.1.0, v4.0.0 |
| 4.0 to 4.1 | [4.0 to 4.1](v4.0-to-v4.1.md) | v4.0.1, v4.0.2, v4.1.0 |
| 4.1.0 to 4.1.1 | [4.1.0 to 4.1.1](v4.1.0-to-v4.1.1.md) | v4.1.1 |
| 4.1.1 to 4.3.0 | [4.1.1 to 4.3.0](v4.1.1-to-v4.3.0.md) | v4.2.0, v4.3.0 |
| 4.3.0 to 4.3.1 | no page: v4.3.1 changes one CI workflow and no module ([changelog](../../CHANGELOG.md#431-2026-10-25)); a consumer on v4.3.0 plans no changes | v4.3.1 |
| 4.3.1 to 4.3.2 | no page: v4.3.2 attaches the Front Door caching rule set to the route (#138). A consumer with `cdn_provider = "azure_front_door"` plans one in-place update of the route and nothing else; any other consumer plans no changes. After apply, `wp-admin/` and `wp-login.php` are no longer cached at the edge and `wp-content/uploads/` and static assets are cached for the configured minutes | v4.3.2 |
| MySQL 8.0 to 8.4 | [MySQL 8.0 to 8.4](mysql-8.0-to-8.4.md) | input added in v4.1.0 |
| PHP security release | [Taking a PHP security release with a dated image tag](php-security-release.md) | any release: `wordpress_version` |

The v2 to v3 page has the Key Vault lifecycle diagram. The PHP security release page is not a module upgrade: it covers the day the PHP project ships a security fix and the floating image tags have not moved, with the registry reads, the proof after the container start, the soak and the rollback. Patch, minor, and major guarantees stay in the repository README under [Version guarantees](../../README.md#version-guarantees).

## How to upgrade

Moved from the repository README:

1. Check the [CHANGELOG](../../CHANGELOG.md) for the target version
2. Look for **BREAKING CHANGES** — these require configuration updates
3. Update the `?ref=` tag in all module source URLs
4. Run `terraform init -upgrade` to fetch the new version
5. Run `terraform plan` to review changes before applying

