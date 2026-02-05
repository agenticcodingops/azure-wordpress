# Storage Module

Layer 2 Application module for Blob Storage (WordPress media uploads).

## Overview

This module creates:
- Storage Account with blob versioning
- Container for WordPress uploads (wp-uploads)
- CORS rules for media access

## IMPORTANT: No Azure Files Mount

This module creates Blob Storage for WordPress media uploads via plugin.
**DO NOT use Azure Files mounts** for `/var/www/html` - this causes:
- 2-3 second page load latency
- Poor IOPS for PHP file operations
- Timeout issues with WordPress admin

Instead, we use:
- Immutable container (WordPress baked into image)
- Azure Blob Storage for media uploads
- Microsoft Azure Storage plugin for WordPress

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| site_name | Site name for resource naming | string | - | yes |
| environment | Environment (nonprod/production) | string | - | yes |
| location | Azure region | string | - | yes |
| resource_group_name | Resource group name | string | - | yes |
| account_tier | Storage tier (Standard/Premium) | string | "Standard" | no |
| account_replication_type | Replication type | string | "LRS" | no |
| container_name | Blob container name | string | "wp-uploads" | no |
| tags | Resource tags | map(string) | {} | no |

## Outputs

| Name | Description |
|------|-------------|
| account_id | Storage Account ID |
| account_name | Storage Account name |
| primary_blob_endpoint | Blob endpoint URL |
| container_name | Container name |
| primary_access_key | Access key (sensitive) |

## Usage

```hcl
module "storage" {
  source = "../modules/layer-2-application/storage"

  site_name           = "workout-tracker"
  environment         = "nonprod"
  location            = "East US"
  resource_group_name = azurerm_resource_group.main.name

  tags = local.tags
}
```

## WordPress Configuration

Configure the Microsoft Azure Storage plugin:
- Account Name: `module.storage.account_name`
- Container: `module.storage.container_name`
- Access Key: Store in Key Vault

## Validation Rules

The module enforces these validations at plan time:

| Variable | Rule | Error Message |
|----------|------|---------------|
| `site_name` | `^[a-z0-9-]+$` | Site name must contain only lowercase letters, numbers, and hyphens |
| `environment` | `nonprod` or `production` | Environment must be 'nonprod' or 'production' |
| `account_tier` | `Standard` or `Premium` | Account tier must be 'Standard' or 'Premium' |
| `account_replication_type` | `LRS`, `GRS`, `RAGRS`, `ZRS`, `GZRS`, `RAGZRS` | Invalid replication type |
| `container_name` | `^[a-z0-9-]+$` | Container name must contain only lowercase letters, numbers, and hyphens |
