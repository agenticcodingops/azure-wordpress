# Basic WordPress Site Example

Deploy a single WordPress site with Cloudflare CDN on Azure.

## Prerequisites

1. Azure subscription with Owner or Contributor access
2. Cloudflare account with a registered domain
3. Terraform >= 1.6.0

## Quick Start

1. Copy the example variables file:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Edit `terraform.tfvars` with your values

3. Initialize and apply:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

## Cost Estimate

| Resource | SKU | Est. Monthly Cost |
|----------|-----|-------------------|
| App Service Plan | B1 | $13 |
| MySQL | B_Standard_B2s | $25 |
| Storage | Standard LRS | $1 |
| Key Vault | Standard | $1 |
| **Total** | | **~$40/month** |

*Cloudflare CDN is free tier eligible*

## Next Steps

- Access WordPress admin at `https://your-domain.com/wp-admin`
- Default credentials are set during first visit
- Configure Azure Storage plugin for media uploads
