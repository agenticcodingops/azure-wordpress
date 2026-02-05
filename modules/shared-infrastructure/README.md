# Shared Infrastructure Module

Creates shared infrastructure resources per environment (subscription) to optimize costs and simplify management.

## Overview

This module creates a shared App Service Plan that hosts multiple WordPress sites within a single subscription/environment. Instead of creating one App Service Plan per site, all sites share a single plan, reducing costs by approximately 50%.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                 Shared Infrastructure (per env)                  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │           rg-trackroutinely-shared-{env}                   │  │
│  │  ┌─────────────────────────────────────────────────────┐  │  │
│  │  │         asp-trackroutinely-shared-{env}              │  │  │
│  │  │              (Shared App Service Plan)               │  │  │
│  │  │                                                      │  │  │
│  │  │   ┌──────────┐  ┌──────────┐  ┌──────────┐         │  │  │
│  │  │   │  Site 1  │  │  Site 2  │  │  Site N  │  ...    │  │  │
│  │  │   │ Web App  │  │ Web App  │  │ Web App  │         │  │  │
│  │  │   └──────────┘  └──────────┘  └──────────┘         │  │  │
│  │  │                                                      │  │  │
│  │  │   Recommended: 8-10 sites per P1v3 plan              │  │  │
│  │  └─────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Cost Savings

| Configuration | App Service Plans | Monthly Cost (B1) |
|---------------|-------------------|-------------------|
| **Before** (1 plan/site) | 4 plans | ~$52 |
| **After** (shared) | 2 plans | ~$26 |
| **Savings** | 50% | ~$26/month |

*Savings increase as more sites are added to the shared plans.*

## Usage

```hcl
# In environment main.tf (e.g., terraform/environments/nonprod/main.tf)

module "shared_infrastructure" {
  source = "../../modules/shared-infrastructure"

  environment     = "nonprod"
  location        = var.location
  app_service_sku = var.shared_app_service_sku  # B1 for dev, P1v3 for prod
  worker_count    = var.shared_worker_count     # Default: 1

  tags = local.common_tags
}

# Pass the shared plan to WordPress sites
module "wordpress_sites" {
  for_each = var.sites
  source   = "../../compositions/wordpress-site"

  # ... other config ...

  # Use shared App Service Plan
  app_service = merge(each.value.app_service, {
    plan_id         = module.shared_infrastructure.app_service_plan_id
    use_shared_plan = true
  })
  shared_resource_group_name = module.shared_infrastructure.resource_group_name
  shared_plan_sku            = module.shared_infrastructure.app_service_plan_sku
}
```

## Resources Created

| Resource | Name Pattern | Purpose |
|----------|--------------|---------|
| Resource Group | `rg-trackroutinely-shared-{env}` | Contains shared resources |
| App Service Plan | `asp-trackroutinely-shared-{env}` | Hosts all WordPress web apps |
| Auto-scale Setting | `autoscale-trackroutinely-shared-{env}` | Optional CPU/memory scaling |

Where `{env}` is `np` for nonprod or `prod` for production.

## Variables

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `environment` | string | *required* | Environment name (`nonprod` or `production`) |
| `location` | string | *required* | Azure region for resources |
| `app_service_sku` | string | `"B1"` | App Service Plan SKU (B1, S1, P1v3, etc.) |
| `worker_count` | number | `1` | Number of instances for the plan |
| `enable_autoscale` | bool | `false` | Enable auto-scaling rules |
| `autoscale_min_workers` | number | `1` | Minimum workers when scaling |
| `autoscale_max_workers` | number | `5` | Maximum workers when scaling |
| `tags` | map(string) | `{}` | Tags to apply to all resources |

## Outputs

| Name | Description |
|------|-------------|
| `resource_group_name` | Name of the shared resource group |
| `resource_group_id` | ID of the shared resource group |
| `app_service_plan_id` | ID of the shared App Service Plan |
| `app_service_plan_name` | Name of the shared App Service Plan |
| `app_service_plan_sku` | SKU of the shared App Service Plan |

## Auto-scaling

When `enable_autoscale = true`, the module creates auto-scale rules:

| Trigger | Metric | Threshold | Action |
|---------|--------|-----------|--------|
| Scale Out | CPU | > 70% (10 min avg) | +1 worker |
| Scale Out | Memory | > 80% (10 min avg) | +1 worker |
| Scale In | CPU | < 50% (15 min avg) | -1 worker |

Cooldown period: 10-15 minutes between scaling actions.

## SKU Recommendations

| Environment | Recommended SKU | Sites per Plan | Features |
|-------------|-----------------|----------------|----------|
| Development | B1 (Basic) | 2-4 | No deployment slots, no auto-scale |
| Staging | S1 (Standard) | 4-6 | Deployment slots, auto-scale |
| Production | P1v3 (Premium) | 8-10 | All features, best performance |

**Important**: Basic tier (B1) does NOT support deployment slots. The wordpress-site composition automatically detects this and skips slot creation.

## Azure Constraints

### Resource Group Requirement

Azure requires App Services to be in the **same resource group** as their App Service Plan. This is why:

1. The shared plan lives in `rg-trackroutinely-shared-{env}`
2. Web apps using the shared plan are created in this same resource group
3. Site-specific resources (database, key vault, etc.) remain in their own resource groups

### Globally Unique Names

App Service names must be globally unique across all Azure subscriptions. The naming pattern `app-trackroutinely-{site}-{env}` ensures uniqueness.

## Migration Notes

When migrating existing sites to use a shared plan:

1. **App Services must be recreated** - Azure doesn't support moving web apps between plans in different resource groups
2. **Custom hostnames rebind automatically** - Terraform handles DNS verification
3. **State cleanup required** - The CI/CD workflow includes steps to:
   - Import existing resources
   - Delete orphaned apps from both site-specific and shared resource groups
   - Remove stale entries from Terraform state

## See Also

- [wordpress-site composition](../../compositions/wordpress-site/README.md) - Uses this module's outputs
- [Environment configuration](../../environments/) - Example usage in nonprod/production
