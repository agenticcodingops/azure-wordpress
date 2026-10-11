# Scheduled App Service backup (app_service_backup_enabled): the container SAS the
# app's backup block uses, generated here and re-issued on a fixed cadence.
#
# Why this file and not modules/storage or modules/app-service: both are called with a
# module-level depends_on, and a data source inside such a module is deferred to apply
# time whenever any depends_on target has a pending change (the deployer read at the
# top of main.tf is placed there for the same reason). Here the read carries no
# depends_on, so Terraform reads it at plan time whenever its arguments are known. On
# the first plan the account does not exist yet, so the read waits for apply; after
# that, every plan reads it unless the storage account itself is being created or
# replaced, or the SAS is rotating. A deferred read is noisy but harmless:
# storage_account_url feeds no identity or ForceNew argument, so the app plans an
# in-place update of its backup block, never a replacement. A caller's depends_on on
# the wordpress-site call defers this read too, one more reason not to add one.
#
# No custom conditions on the data source: a precondition or postcondition makes
# Terraform defer the read whenever anything it depends on, directly or indirectly,
# has a pending change. The container check sits on azurerm_resource_group.main.

# The rotation timestamp the SAS window hangs off. time_rotating keeps it in state and
# proposes a replacement only once sas_rotation_days have passed, so the SAS is stable
# between rotations and the first plan after the rotation date shows the replacement.
# timestamp() would re-issue the SAS on every plan.
resource "time_rotating" "backup_sas" {
  count = var.app_service_backup_enabled ? 1 : 0

  rotation_days = var.app_service_backup.sas_rotation_days
}

# The SAS start: the rotation timestamp backdated by 15 minutes, as Microsoft's SAS
# guidance asks, so clock skew between App Service and the storage service cannot make
# a freshly issued SAS invalid. Derived from the rotation timestamp, so it is as stable
# as the rotation itself.
resource "time_offset" "backup_sas_start" {
  count = var.app_service_backup_enabled ? 1 : 0

  base_rfc3339   = time_rotating.backup_sas[0].rfc3339
  offset_minutes = -15
}

# The SAS expiry, measured from the rotation timestamp. The validation on
# app_service_backup keeps validity at least twice the rotation interval, so the SAS a
# rotation replaces stays valid for at least one more interval while the rotation
# waits to be applied.
resource "time_offset" "backup_sas_expiry" {
  count = var.app_service_backup_enabled ? 1 : 0

  base_rfc3339 = time_rotating.backup_sas[0].rfc3339
  offset_days  = var.app_service_backup.sas_validity_days
}

# A service SAS for the one backup container, signed locally with the account key
# carried by the storage module's connection string; nothing is sent to Azure. The
# permissions are the set Microsoft's own backup sample grants (read, write, delete,
# list); the first backup proves them. The account's 7-day sas_policy only logs a
# longer SAS, it does not reject it.
data "azurerm_storage_account_blob_container_sas" "backup" {
  count = var.app_service_backup_enabled ? 1 : 0

  connection_string = module.storage.primary_connection_string
  container_name    = var.app_service_backup.container_name
  https_only        = true

  start  = time_offset.backup_sas_start[0].rfc3339
  expiry = time_offset.backup_sas_expiry[0].rfc3339

  permissions {
    read   = true
    write  = true
    delete = true
    list   = true
    add    = false
    create = false
  }
}

locals {
  # The SAS URL the app's backup block takes: the account's blob endpoint (which ends
  # in a slash), the container, and the SAS query string (which starts with "?").
  # Sensitive through the sas attribute, and null when the backup is off.
  app_service_backup_storage_account_url = var.app_service_backup_enabled ? "${module.storage.primary_blob_endpoint}${var.app_service_backup.container_name}${data.azurerm_storage_account_blob_container_sas.backup[0].sas}" : null
}
