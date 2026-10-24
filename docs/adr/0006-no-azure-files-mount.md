# 0006: Do not mount Azure Files

**Status:** Accepted  
**Date:** 2026-02-05  
**Code commit:** `0ca9c63afe42ba866bc0a9b748946448a699da2b`

## Context

The web app has persistent `/home` storage, while the storage module supplies blob storage for optional media offload and backups.

## Decision

Do not configure an App Service `storage_account` block and therefore do not mount Azure Files.

## Consequences

The default runtime avoids an Azure Files dependency and its latency. Adopters who want Blob-backed media must install and configure an offload plugin; they must not assume the provisioned storage account is mounted into the container. Reason not recorded beyond the documented latency trade-off.

## Code

- `modules/app-service/main.tf:231-245` — configures the site and container without a storage_account mount block.
- `docs/architecture.md:388-393` — describes `/home`, optional Blob offload, and the absence of an Azure Files mount.
