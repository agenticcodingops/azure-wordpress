# MySQL major-version upgrade

## When to use

An existing site's MySQL Flexible Server runs 8.0 (`database.mysql_version = "8.0.21"`, the default and the version every
earlier server was created with) and you want it on 8.4. A new server created with `"8.4"` needs none of this.

**This is an in-place, irreversible major-version upgrade.** The findings below come from issue #70, which cites the
provider source and a real plan; this repository's README and the input's description do not yet state them, and the
[MySQL 8.0 to 8.4](../upgrading/mysql-8.0-to-8.4.md) page still marks them **UNKNOWN**. Treat the General Purpose and
Memory Optimized path below as the sourced one, and the Burstable path as **unmeasured: to be confirmed by a real run**.

What the sources say:

- **In place with every azurerm this repository accepts.** `version` on `azurerm_mysql_flexible_server` forced replacement
  through azurerm 4.33.0 and became updatable in 4.34.0, and every module here requires azurerm `~> 5.6`. At 5.7.0 a
  plan with the server at `8.0.21` prints `~ version = "8.0.21" -> "8.4"` and `0 to add, 1 to change, 0 to destroy`.
  The provider sends the version in a PATCH of its own, after any other changed property.
- **Irreversible.** Microsoft asks for an on-demand backup first. Going back means restoring a pre-upgrade backup to a
  new server ([Microsoft Learn, major version upgrade](https://learn.microsoft.com/en-us/azure/mysql/flexible-server/how-to-upgrade)).
- **Burstable needs a General Purpose step.** Microsoft documents the Burstable upgrade only as a portal workflow that
  first moves the server to General Purpose. The Azure CLI refuses a major upgrade on the Burstable tier, per
  issue #70's reading of the CLI source. The provider has no such check.
- **A plan validation cannot protect you.** A variable cannot tell an upgrade from a new server, and rejecting `"8.4"`
  on a Burstable SKU would also reject creating a supported 8.4 Burstable server.

## Prerequisites

- A rehearsal on a restored copy. Microsoft recommends upgrading a restored copy first. Restore one with
  [the point-in-time restore steps](backup-and-restore.md#2-mysql-point-in-time-restore) and upgrade **that server** with
  Azure's own workflow, not with Terraform: the module's `mysql_version` input only ever targets the site's existing
  server, so changing it would upgrade the original. For a General Purpose or Memory Optimized copy:

  ```bash
  az mysql flexible-server upgrade --resource-group <resource-group> --name <restored-server-name> --version 8.4
  ```

  Then run the schema check below and your own SQL against the copy from a client in the network. **This rehearsal covers
  the upgrade, the schema and SQL, not WordPress itself:** the composition wires `DATABASE_HOST` to the site's own server
  (`modules/wordpress-site/main.tf`), so the site's app and slot cannot reach the copy. To exercise the image and plugins
  on 8.4 you would need a throwaway app, outside Terraform and in the same network, with `DATABASE_HOST` set to the copy's
  host name. That setup is not covered here and has not been tried. A Burstable copy needs the portal workflow (see the
  Burstable section). Delete the copy afterwards. Finish the rehearsal before you touch the site's configuration.
- The server's SKU tier. `database.sku_name` defaults by environment: nonprod is `B_Standard_B2s` (Burstable) and
  production is `GP_Standard_D2ds_v4` (General Purpose) when you set nothing
  ([README](../../README.md#environment-aware-defaults)).
- A way to run client tools inside the VNet. The server has no public endpoint and admits port 3306 only from the app
  subnet, so the checks below run from the app's SSH console or another host in that network. Whether MySQL Shell can be
  installed in the app's container was not verified here; plan another host if it cannot.
- A quiet period. Microsoft gives no fixed duration for the upgrade (it "depends on the size and activity" of the
  database), and the site's database is unavailable while it runs. Put the site in a maintenance window.
- No read replicas, or you upgrade them first (the module creates none).

## Steps (General Purpose and Memory Optimized)

1. **Remove unsupported `sql_mode` values.** Microsoft names `NO_AUTO_CREATE_USER`, `NO_FIELD_OPTIONS`,
   `NO_KEY_OPTIONS` and `NO_TABLE_OPTIONS` as no longer supported, and says leftover deprecated values make the
   upgrade fail. This module sets no `sql_mode`; check the server parameter if someone changed it outside Terraform.
2. **Check for XA transactions** in the `prepared` state; ongoing ones can fail the upgrade. From a client connected to
   the server run `XA RECOVER CONVERT XID;`. Roll back each listed transaction with its complete identifier: the `data`
   column is the transaction's `gtrid` followed by its `bqual`. `gtrid_length` and `bqual_length` count **bytes**, and each
   byte of the converted `data` is two hex characters. Ignoring any `0x` prefix, the `gtrid` is the first
   `2 * gtrid_length` characters and the `bqual` the next `2 * bqual_length`. Write each part as `X'<hex>'`, which also
   covers an empty part as `X''` (a bare `0x` with no digits is not a valid literal), and run
   `XA ROLLBACK X'<gtrid-hex>', X'<bqual-hex>', <formatID>;` (Microsoft's shorter `XA ROLLBACK '{xid}';` fits only
   a transaction with no branch qualifier and the default format ID). The syntax is in the
   [MySQL XA reference](https://dev.mysql.com/doc/refman/8.4/en/xa-statements.html). Run `XA RECOVER;` again: it must list
   nothing.
3. **Run the schema compatibility check.** Online validation is not supported for 8.0 to 8.4, so Microsoft points to
   Oracle's MySQL Shell upgrade checker:

   ```text
   mysqlsh> util.checkForServerUpgrade('<user>@<server-fqdn>:3306', {"targetVersion": "8.4.0"})
   ```

   The function and its `targetVersion` option are from MySQL's documentation. Fix what it reports. Pass the password
   through the prompt, not the options dictionary.
4. **Take an on-demand backup** and note its name ([Backup and restore](backup-and-restore.md)):

   ```bash
   az mysql flexible-server backup create --resource-group <resource-group> --name <server-name> --backup-name pre-8-4-upgrade
   az mysql flexible-server backup list --resource-group <resource-group> --name <server-name>
   ```

5. **Set the version.** Keep the other keys of the `database` object you already use: a key you leave out takes its
   default again (for `sku_name`, the environment default), so dropping one can plan an unrelated change:

   ```hcl
   database = {
     # ... your existing keys (sku_name, storage_size_gb, ...) ...
     mysql_version = "8.4"
   }
   ```

6. **Plan and read it.** It must show exactly one in-place change, `version = "8.0.21" -> "8.4"` on
   `module.<site>.module.database.azurerm_mysql_flexible_server.main`, with `0 to destroy` and no `forces replacement`.
   Stop if it shows a replacement: that is an older provider, and replacing destroys the data.
7. **Apply in the maintenance window**, nonprod first. Watch the server's state:

   ```bash
   az mysql flexible-server show --resource-group <resource-group> --name <server-name> --query "{state:state, version:version}" -o json
   ```

   Wait for `Ready` and a version of `8.4`.
8. **Keep `mysql_version = "8.4"` from now on.** Removing it or setting it back plans a downgrade, which Azure does not
   support; the input's default is `8.0.21`.

## Steps (Burstable): unmeasured, to be confirmed by a real run

Issue #70's proposed procedure, which no run has confirmed. Rehearse it first on a restored copy, using Microsoft's portal
workflow below, because the Azure CLI refuses a major upgrade on Burstable and the module cannot target the copy.

1. Do steps 1 to 4 above.
2. **Upgrade and resize in one apply.** In the configuration set `database.sku_name` to a General Purpose SKU (for
   example `GP_Standard_D2ds_v4`) **and** `mysql_version = "8.4"`. The provider resizes first and sends the version in its
   own request. Each compute change restarts the server.
3. Check the server: General Purpose, `8.4`, `Ready`.
4. **Return to Burstable in a later apply:** set `database.sku_name` back to the Burstable SKU, or remove the override
   so the nonprod default applies. Keep `mysql_version = "8.4"`.
5. Check the server again.

Microsoft's own portal workflow for Burstable moves the server to General Purpose, upgrades it, and (by choice) returns it
to Burstable, defaulting to `B2S`. That is a different path from the one above and is not what this module does.

## Verify

- `az mysql flexible-server show` reports `version` `8.4` and `state` `Ready`.
- The site's pages that read the database work, and the administration screen opens. From the app's SSH console:

  ```bash
  wp db query "SELECT VERSION();" --path=/home/site/wwwroot --allow-root
  ```

  WP-CLI is used the same way in [deployment guide step 12](../deployment-guide.md#step-12-remove-a-site); expect a version
  that starts with `8.4`.
- A re-plan reports no changes. The tables the schema check flagged behave as expected in the application.
- The slow query log and the MySQL alert rules still exist (`alert-mysql-*`) if you use them.

## Rollback

There is no in-module rollback. The upgrade cannot be undone on the same server, and the module cannot downgrade it.

- **Before the apply:** revert the pull request; nothing changed.
- **After the apply:** restore the pre-upgrade backup to a **new** server (Microsoft's documented route). The CLI's
  `az mysql flexible-server restore` takes a `--restore-time`; whether it can target a named on-demand backup, and the
  network placement it picks for a server created by this module, were not verified here, so use the portal's restore
  for the backup you took, and read its Networking tab. The result is a server this module does not manage. Recover the
  site's data from it as in [Backup and restore](backup-and-restore.md#2-mysql-point-in-time-restore) (dump and import into
  the module's server), or plan a rebuild. Moving the module onto a restored server by importing it into state is not
  covered here and has not been tried.
- Do not try to lower `mysql_version` as a rollback.

## Sources

Issue #70 (provider behaviour, plan result, Burstable limits), `modules/database/variables.tf` (`mysql_version`,
validated to `8.0.21` or `8.4`), `modules/database/main.tf`, `modules/wordpress-site/variables.tf` (`database`),
[Microsoft Learn](https://learn.microsoft.com/en-us/azure/mysql/flexible-server/how-to-upgrade),
[MySQL Shell upgrade checker](https://dev.mysql.com/doc/mysql-shell/8.4/en/mysql-shell-utilities-upgrade.html).
