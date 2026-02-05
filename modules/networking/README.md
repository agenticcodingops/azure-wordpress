# Networking Module

Layer 1 Foundation module for creating isolated networking infrastructure per WordPress site.

## Overview

This module creates:
- Virtual Network (VNet) with site-specific address space
- App Service integration subnet (delegated to Microsoft.Web/serverFarms)
- Database subnet (delegated to Microsoft.DBforMySQL/flexibleServers)
- Private Endpoint subnet for Storage/Key Vault
- Network Security Groups (NSGs) with least-privilege rules

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Virtual Network                       │
│                    (10.0.0.0/16)                        │
│                                                         │
│  ┌─────────────────┐  ┌─────────────────┐              │
│  │   App Subnet    │  │    DB Subnet    │              │
│  │  (10.0.0.0/24)  │  │  (10.0.1.0/24)  │              │
│  │                 │  │                 │              │
│  │  App Service    │─▶│  MySQL Server   │              │
│  │  VNet Int.      │  │  (delegated)    │              │
│  │  (delegated)    │  │                 │              │
│  └─────────────────┘  └─────────────────┘              │
│                                                         │
│  ┌─────────────────┐                                   │
│  │   PE Subnet     │                                   │
│  │  (10.0.2.0/24)  │                                   │
│  │                 │                                   │
│  │  Private        │                                   │
│  │  Endpoints      │                                   │
│  └─────────────────┘                                   │
└─────────────────────────────────────────────────────────┘
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| site_name | Site name for resource naming | string | - | yes |
| environment | Environment (nonprod/production) | string | - | yes |
| location | Azure region | string | - | yes |
| resource_group_name | Resource group name | string | - | yes |
| vnet_address_space | VNet CIDR block | string | "10.0.0.0/16" | no |
| app_subnet_cidr | App subnet CIDR | string | "10.0.0.0/24" | no |
| db_subnet_cidr | Database subnet CIDR | string | "10.0.1.0/24" | no |
| private_endpoint_subnet_cidr | PE subnet CIDR | string | "10.0.2.0/24" | no |
| tags | Resource tags | map(string) | {} | no |

## Outputs

| Name | Description |
|------|-------------|
| vnet_id | Virtual Network ID |
| vnet_name | Virtual Network name |
| app_subnet_id | App Service subnet ID |
| db_subnet_id | Database subnet ID |
| private_endpoint_subnet_id | Private Endpoint subnet ID |

## Usage

```hcl
module "networking" {
  source = "../modules/layer-1-foundation/networking"

  site_name           = "workout-tracker"
  environment         = "nonprod"
  location            = "East US"
  resource_group_name = azurerm_resource_group.main.name

  tags = {
    Environment = "nonprod"
    ManagedBy   = "terraform"
  }
}
```

## Security

- NSGs implement least-privilege access
- App subnet only allows HTTPS from Azure Front Door
- Database subnet only allows MySQL (3306) from App subnet
- All other inbound traffic is denied

## Validation Rules

The module enforces these validations at plan time:

| Variable | Rule | Error Message |
|----------|------|---------------|
| `site_name` | `^[a-z0-9-]+$` | Site name must contain only lowercase letters, numbers, and hyphens |
| `environment` | `nonprod` or `production` | Environment must be 'nonprod' or 'production' |
| `vnet_address_space` | Valid CIDR block | VNet address space must be a valid CIDR block |
| `app_subnet_cidr` | Valid CIDR block | App subnet CIDR must be a valid CIDR block |
| `db_subnet_cidr` | Valid CIDR block | Database subnet CIDR must be a valid CIDR block |
| `private_endpoint_subnet_cidr` | Valid CIDR block | Private endpoint subnet CIDR must be a valid CIDR block |
