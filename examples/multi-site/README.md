# Multi-Site WordPress Example

Deploy multiple WordPress sites sharing a single App Service Plan for cost optimization.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│           Shared Resource Group                         │
│  ┌───────────────────────────────────────────────────┐  │
│  │         Shared App Service Plan (B1/P1v3)         │  │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐  │  │
│  │  │  main-site  │ │    blog     │ │    docs     │  │  │
│  │  │  WordPress  │ │  WordPress  │ │  WordPress  │  │  │
│  │  └─────────────┘ └─────────────┘ └─────────────┘  │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│       Per-Site Resource Groups (Isolated)               │
│  ┌─────────────────┐  ┌─────────────────┐              │
│  │ MySQL (site 1)  │  │ MySQL (site 2)  │  ...         │
│  │ Storage         │  │ Storage         │              │
│  │ Key Vault       │  │ Key Vault       │              │
│  │ VNet            │  │ VNet            │              │
│  └─────────────────┘  └─────────────────┘              │
└─────────────────────────────────────────────────────────┘
```

## Cost Comparison

| Deployment | Sites | App Service Plans | Est. Monthly Cost |
|------------|-------|-------------------|-------------------|
| Dedicated plans | 3 | 3 x B1 ($13) | $39 + $75 (MySQL) = ~$114 |
| **Shared plan** | 3 | 1 x B1 ($13) | $13 + $75 (MySQL) = ~$88 |

**Savings: ~23% with 3 sites, increases with more sites**

## Usage

1. Copy and configure variables:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars with your values
   ```

2. Deploy:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

## Scaling

- **Add sites**: Add entries to `sites` map in terraform.tfvars
- **Remove sites**: Remove entries (7-day soft delete enabled)
- **Scale up**: Change `app_service_sku` (e.g., B1 → P1v3)

## Capacity Guidelines

| SKU | Max Sites | Use Case |
|-----|-----------|----------|
| B1 | 2-3 | Development, low traffic |
| P1v3 | 8-10 | Production, moderate traffic |
| P2v3 | 15+ | High traffic |

Monitor CPU/memory in Azure Portal and scale when needed.
