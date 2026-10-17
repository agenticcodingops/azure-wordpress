# Backup and restore

## When to use

Before a risky change, to check that a restore point exists, or to recover a site. Two mechanisms protect a site and
they cover different data:

| Mechanism | Covers | Configured by | Restores to |
| --- | --- | --- | --- |
| MySQL point-in-time restore (PITR) | The database | `database.backup_retention_days` (1 to 35 days), `database.geo_redundant_backup` | A **new** server |
| App Service custom backup | The app's `/home` (WordPress core, themes, plugins, uploads) and its configuration, **not** the database | `app_service_backup_enabled`, `app_service_backup` | A new app, a slot, or an overwrite of the app |

No App Service backup includes the database, and the module does not try: custom backups cannot link a MySQL Flexible
Server. To restore a whole site, restore the database to the same moment as the files
([README, Backup & Recovery](../../modules/wordpress-site/README.md#backup--recovery)).

> **App Service backup status.** Issue #57 asked for the scheduled App Service backup, and it shipped in v4.3.0
> (`feat(app-service): add scheduled App Service backup`, `CHANGELOG.md`). Section 3 documents what the code in
> `modules/app-service/main.tf` and `modules/wordpress-site/backup.tf` does today. On a release before v4.3.0 the
> inputs do not exist: skip section 3.

## Prerequisites

- Rights to read and change resources in the site's resource group.
- Network reach, for any step that touches data: the MySQL server has no public endpoint and admits port 3306 only
  from the app subnet, and the storage account denies public access by default. Work from the app's SSH console
  (`az webapp ssh --resource-group <resource-group> --name <app-name>`) for database work.
- For section 3, `app_service_backup_enabled = true`, a private container declared in `storage.additional_containers`
  (default name `wp-backups`), and an app on a Basic, Standard or Premium SKU.

## Steps

### 1. Know what protects the site

```bash
az mysql flexible-server show --resource-group <resource-group> --name <server-name> -o json
az webapp config backup list --resource-group <resource-group> --webapp-name <app-name> -o json
```

In the first output read the backup retention, the geo-redundancy setting and the earliest restore time; they decide
how far back a restore can go. The second lists the backups App Service has made (custom ones appear once the
schedule has run). The field names were not checked against a live server here.

Defaults when you set nothing: production keeps 30 days with geo-redundant backup, nonprod keeps 7 days without
(`modules/wordpress-site/main.tf`, [README, Environment-aware Defaults](../../README.md#environment-aware-defaults)).
`geo_redundant_backup` is fixed when the server is created: changing it on an existing server replaces the server.

### 2. MySQL point-in-time restore

**A PITR restore always creates a new server.** It cannot overwrite the module's server, and the module has no input
for pointing a site at a different server. Use it to recover data, not to swap servers.

1. **Take an on-demand backup first** if you are about to change something (an upgrade, a bulk update):

   ```bash
   az mysql flexible-server backup create --resource-group <resource-group> --name <server-name> --backup-name pre-change-<date>
   az mysql flexible-server backup list --resource-group <resource-group> --name <server-name>
   ```

2. **Restore to a point in time** (UTC, ISO 8601) before the damage, under a new name:

   ```bash
   az mysql flexible-server restore --resource-group <resource-group> --name <restored-server-name> \
     --source-server <server-name> --restore-time "<YYYY-MM-DDTHH:MM:SSZ>"
   ```

   The restore needs a network placement for a private-access server. The CLI has `--vnet`, `--subnet`,
   `--address-prefixes`, `--subnet-prefixes` and `--private-dns-zone` for it. Which placement the CLI picks when you pass
   none for a server created by this module was not verified here: set them explicitly, or restore from the portal
   and read the Networking tab. A restored copy left in the site's database subnet stops that subnet from being deleted.
3. **Check the copy** before you rely on it: it is `Ready`, and the tables you need are there.

   ```bash
   az mysql flexible-server show --resource-group <resource-group> --name <restored-server-name> --query state -o tsv
   ```

4. **Bring the data back into the module's server.** Dump the affected tables from the restored server and import them
   into the module's server, from the app's SSH console. This path was **not measured** end to end: the client tools
   in the image, the restored server's login and its firewall placement are assumptions to confirm in nonprod first.
   `wp db export /home/backups/wordpress.sql --path=/home/site/wwwroot --allow-root` works against the module's own
   server, as in [deployment guide step 12](../deployment-guide.md#step-12-remove-a-site). Never write a dump under
   `/home/site/wwwroot`, the public web root, and delete it afterwards.
5. **Delete the restored server** when you are done; it bills while it exists:

   ```bash
   az mysql flexible-server delete --resource-group <resource-group> --name <restored-server-name> --yes
   ```

A **deleted** server can be restored for up to five days through the REST API, only while its backup exists and its
resource group exists ([deployment guide, Rollback](../deployment-guide.md#rollback)).

### 3. App Service custom backup

#### Schedule it

```hcl
storage = {
  additional_containers = { "wp-backups" = {} } # private; the module does not create the container itself
}

app_service_backup_enabled = true
app_service_backup = {
  container_name           = "wp-backups"
  frequency_interval       = 1
  frequency_unit           = "Day" # or "Hour", with an interval of at least 2
  retention_period_days    = 30    # 0 to 30; 0 keeps backups indefinitely
  keep_at_least_one_backup = true
}
```

Facts the code enforces (`modules/app-service/main.tf`, `modules/wordpress-site/backup.tf`, `variables.tf`):

- Only the production app is backed up, never the staging slot.
- At most one backup every 2 hours; the plan fails on `frequency_unit = "Hour"` with an interval below 2.
- Retention is 0 to 30 days; the plan rejects more.
- A backup is capped at **10 GB** and fails above it. Measure `/home` first (the Kudu console) and exclude paths with a
  `_backup.filter` file if needed; excluding paths on a Linux app is unproven ([README, Backup & Recovery](../../modules/wordpress-site/README.md#backup--recovery), "The 10 GB limit").
- The module signs a container SAS with the account key and re-issues it on a schedule. Removing the container entry
  from `storage.additional_containers` later destroys the container and every backup in it.
- Backups travel over the VNet integration (`virtual_network_backup_restore_enabled`), so the storage account can stay
  on `storage_network_rules_default_action = "Deny"`.

Enable it in nonprod, confirm the first backup succeeded (`az webapp config backup list` above), then production.

#### Restore it

App Service restores to a **new app or slot**, or overwrites an existing one; the target stops while it runs. Prefer
the staging slot (on an S\* or P\* SKU) and swap. A restore brings files and, optionally, settings, but not VNet
integration, managed identities, TLS bindings or the backup configuration. Restoring into the module's own app or slot
keeps everything the module manages. A **new** app has a new identity with no Key Vault access policy, so its Key Vault
references do not resolve until you grant one.

1. **Make a short-lived container SAS** for the restore. It is yours, not the module's; keep it out of logs and
   shell history, and let it expire.

   ```bash
   end="$(date -u -d '+2 hours' '+%Y-%m-%dT%H:%MZ')"   # GNU date
   sas="$(az storage container generate-sas --account-name <storage-account> --name wp-backups \
     --permissions rwdl --expiry "$end" --https-only --auth-mode key -o tsv)"
   ```

2. **Restore into the staging slot:**

   ```bash
   az webapp config backup restore --resource-group <resource-group> --webapp-name <app-name> --slot staging \
     --backup-name <backup-name> --container-url "https://<storage-account>.blob.core.windows.net/wp-backups?$sas" --overwrite
   ```

   `--overwrite` is documented as "overwrite the source web app, if `--target-name` is not specified". Whether the CLI
   needs it when `--slot` is given was not verified; the app's Backups page in the portal does the same restore.
3. **Check the slot**, then swap it into production:

   ```bash
   az webapp deployment slot swap --resource-group <resource-group> --name <app-name> --slot staging --target-slot production
   ```

4. **Restore the database to the same moment** (section 2) if the data changed since the file backup.

### 4. Automatic and blob-level protection

App Service also makes automatic backups on Basic and higher with no configuration (hourly, kept 30 days, up to
30 GB, restorable from the app's Backups page), but Microsoft does not recommend them as a disaster-recovery plan,
and they cannot be downloaded or filtered. The storage account has blob versioning and soft delete on by default
(`storage.versioning_enabled`, `blob_delete_retention_days`, `container_delete_retention_days`); blob soft delete does
not protect against deleting the storage account itself.

## Verify

- A new custom backup exists after each scheduled time (`az webapp config backup list`).
- A restore rehearsal into nonprod succeeded: the slot serves the pages, and the media you expect is present.
- A PITR restore of nonprod produced a server whose tables match what you expected.
- Do a rehearsal before you need one. An unrehearsed backup is a guess.

## Rollback

- **A bad slot restore:** swap back (`az webapp deployment slot swap` with the same arguments); the previous production
  content is now in the slot. Do this before anything else writes to either.
- **A restore you do not want to keep:** delete the restored MySQL server (above). Terraform never managed it.
- **A restore over production (`--overwrite`):** there is no undo except another backup. Take a fresh one first.

## Sources

`modules/wordpress-site/backup.tf`, `modules/app-service/main.tf` (`backup` block and
`virtual_network_backup_restore_enabled`), `modules/wordpress-site/variables.tf` (`app_service_backup`),
`modules/database/main.tf`, [README, Backup & Recovery](../../modules/wordpress-site/README.md#backup--recovery),
[deployment guide](../deployment-guide.md).
