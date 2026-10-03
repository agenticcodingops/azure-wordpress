# Cost guide

## Purpose

This page holds the one cost table for this module. The README and the examples link here instead of
carrying their own figures.

- **Prices:** Azure pay-as-you-go list prices, in US dollars, for the **East US** (`eastus`) region.
- **Date:** fetched on **2026-10-03** from the [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices).
  The MySQL figures were also checked against the
  [Azure Database for MySQL pricing page](https://azure.microsoft.com/en-us/pricing/details/mysql/flexible-server/), which showed East US.
- **Month:** 730 hours, the convention the Azure pricing pages use.
- **Code:** every `file:line` reference is at commit
  [`9cf59db`](https://github.com/agenticcodingops/azure-wordpress/tree/9cf59dbf1f984a2e043cd7b6180187dda8cfcd5a),
  which is release v4.1.1.

East US is used because it is the examples' default `location` (`examples/basic-site/variables.tf:24`).
Prices differ by region. Taxes, reservations, savings plans and data transfer out of Azure are not included.

## When to use

- Before a first deployment, to size the bill.
- When you choose between a dedicated App Service plan per site and one shared plan.
- When you choose a CDN provider.

## Prerequisites

None. To re-price for another region or date, you need `curl` and `jq`.

## Price table

"Usage" means the cost depends on traffic or data volume, so no fixed monthly figure is given.

| # | Component | What the module creates by default | Unit price (East US, USD) | Monthly |
|---|---|---|---|---|
| 1 | App Service plan, Linux **B1** | Default SKU of the shared plan (`modules/shared-infrastructure/variables.tf:28-31`) | $0.017 per hour | **$12.41** |
| 2 | App Service plan, Linux **S1** | The SKU used by [getting started](getting-started.md) | $0.095 per hour | **$69.35** |
| 3 | App Service plan, Linux **P1v3** | Default `app_service.sku_name` for a dedicated plan (`modules/wordpress-site/variables.tf:281`) | $0.155 per hour | **$113.15** |
| 4 | Staging slot | One slot on S\* and P\* plans (`modules/app-service/main.tf:24`, `:331-332`) | No extra charge ([Microsoft Learn](https://learn.microsoft.com/en-us/azure/app-service/deploy-staging-slots)) | $0.00 |
| 5 | MySQL Flexible Server, Burstable **B2s** | Nonprod default `database.sku_name` (`modules/wordpress-site/main.tf:98`) | $0.068 per hour | **$49.64** |
| 6 | MySQL Flexible Server, General Purpose **D2ds_v4** | Production default `database.sku_name` (`modules/wordpress-site/main.tf:98`) | $0.0855 per vCore-hour × 2 vCores | **$124.83** |
| 7 | MySQL storage | 100 GB (`modules/wordpress-site/variables.tf:89`) | $0.115 per GB-month | **$11.50** |
| 8 | MySQL pre-provisioned IOPS | 700 IOPS (`modules/wordpress-site/variables.tf:90`) | $0.05 per IOPS-month for additional IOPS | **UNKNOWN**, between $0.00 and $35.00 (see note 1) |
| 9 | MySQL backup storage | 7 days nonprod, 30 days production; geo-redundant in production (`modules/wordpress-site/main.tf:101-102`) | Free up to 100% of provisioned storage, then $0.095 per GB-month; geo-redundant backup is charged at 2× | Usage |
| 10 | Private DNS zone | One per site, for MySQL (`modules/dns-zones/main.tf:7-8`) | $0.50 per zone-month (first 25 zones) | **$0.50** |
| 11 | Virtual network and App Service VNet integration | One VNet per site (`modules/wordpress-site/main.tf:221-236`) | Free ([VNet pricing](https://azure.microsoft.com/en-us/pricing/details/virtual-network/), [VNet integration](https://learn.microsoft.com/en-us/azure/app-service/overview-vnet-integration)) | $0.00 |
| 12 | Blob storage, Standard LRS, Hot | One account per site (`modules/storage/variables.tf:88-102`) | $0.0208 per GB-month; writes $0.05 per 10,000; reads $0.004 per 10,000 | Usage |
| 13 | Key Vault, Standard | One vault per site (`modules/key-vault/main.tf:39`) | $0.03 per 10,000 operations | Usage |
| 14 | Log Analytics (also holds Application Insights data) | One workspace per site unless you pass your own (`modules/wordpress-site/main.tf:260-270`) | First 5 GB a month per billing account free, then $2.30 per GB ingested. Retention beyond the included period: $0.10 per GB-month (see note 2) | Usage |
| 15 | Metric alert rules | Three baseline alerts when `alert_recipients` or `extra_action_group_ids` is set (`modules/wordpress-site/main.tf:671-772`) | First 10 time series a month $0.00, then $0.10 per time series | $0.00 to $0.30 |
| 16 | Log search alert, 5xx rate (opt-in) | Evaluates every 5 minutes by default (`modules/wordpress-site/variables.tf:386`) | $1.50 per rule-month at a 5-minute frequency | $1.50 when enabled |
| 17 | Standard availability test (opt-in) | Every 300 s from 5 locations by default (`modules/wordpress-site/variables.tf:692-694`) | $0.0005 per test run | $21.90 per test (43,800 runs) |
| 18 | Azure Front Door **Standard** | Only with `cdn_provider = "azure_front_door"` and `front_door.sku_name = "Standard_AzureFrontDoor"` | $35.00 per month base fee, plus requests and data transfer | **$35.00** + usage |
| 19 | Azure Front Door **Premium** | The module's default Front Door SKU (`modules/wordpress-site/variables.tf:315`) | $330.00 per month base fee, plus requests and data transfer | **$330.00** + usage |
| 20 | **Total, getting started** (nonprod, S1 dedicated plan, no CDN) | Rows 2 + 5 + 7 + 10 | | **$130.99** + row 8 + usage |
| 21 | **Total, production defaults** (P1v3 dedicated plan, no CDN) | Rows 3 + 6 + 7 + 10 | | **$249.98** + row 8 + usage |

Notes:

1. **IOPS.** The module provisions 700 IOPS. Microsoft's pages say that pre-provisioned IOPS are "paid for
   regardless of usage", and that additional IOPS cost $0.05 per IOPS-month. They do not say how many IOPS are
   included with the storage. So the IOPS charge is **UNKNOWN**: at most 700 × $0.05 = $35.00 a month.
   Check the first invoice, or the meter in Azure Cost Management.
2. **Log retention.** Analytics Logs include 31 days of retention, and Application Insights data includes 90 days
   ([Azure Monitor pricing](https://azure.microsoft.com/en-us/pricing/details/monitor/)). The workspace keeps
   30 days in nonprod and 90 days in production (`modules/wordpress-site/main.tf:168`). So in production, the
   App Service and MySQL log tables are charged retention for the days beyond 31.
3. **Cloudflare** plan fees are not Azure prices, so they are not in the table. The module's Cloudflare defaults
   are chosen to work on the Free plan. `cloudflare.enable_waf` needs Pro or higher
   (`modules/wordpress-site/variables.tf:344`). See [Cloudflare plans](https://www.cloudflare.com/plans/).
4. **Front Door SKU.** With `cdn_provider = "azure_front_door"` and no `front_door.sku_name`, the module creates a
   **Premium** profile (`modules/wordpress-site/main.tf:142`). Set `front_door.sku_name = "Standard_AzureFrontDoor"`
   if you do not need Premium.

## Steps

### 1. Estimate a dedicated plan per site

**Who:** operator. **STOP:** no.

Add one App Service row, one MySQL compute row, row 7 and row 10, for each site. Then add the opt-in rows you
enable. Row 20 is the getting-started configuration. Row 21 is a production site that keeps every default.

### 2. Estimate a shared plan

**Who:** operator. **STOP:** no.

A shared plan is paid once. Every site still pays for its own MySQL server, storage, Key Vault and DNS zone,
because the site module creates those per site (`modules/wordpress-site/main.tf:291-437`). The
[deployment guide](deployment-guide.md#step-11-host-several-sites-on-a-shared-plan) explains the shared plan.

Worked example: three nonprod sites, each on Burstable B2s with 100 GB, excluding row 8 and usage.

| Layout | Plan cost | Per-site cost (rows 5 + 7 + 10) | Total |
|---|---|---|---|
| Three dedicated S1 plans | 3 × $69.35 | 3 × $61.64 | $392.97 |
| One shared S1 plan | $69.35 | 3 × $61.64 | $254.27 |
| One shared B1 plan (no slots) | $12.41 | 3 × $61.64 | $197.33 |

How many sites one plan can carry is **UNKNOWN**: it depends on traffic, plugins and PHP memory. The module
limits PHP to 256 MB per worker because plans are shared (`modules/app-service/main.tf:87-94`). Watch the
plan's CPU and memory metrics after each site you add.

### 3. Re-price for another region or date

**Who:** operator. **STOP:** no.

Query the Retail Prices API. For example, Linux App Service in West Europe:

```bash
curl -sS "https://prices.azure.com/api/retail/prices?\$filter=serviceName%20eq%20'Azure%20App%20Service'%20and%20armRegionName%20eq%20'westeurope'%20and%20priceType%20eq%20'Consumption'" \
  | jq -r '.Items[] | select(.productName | test("Linux")) | [.productName, .skuName, .unitOfMeasure, .retailPrice] | @tsv'
```

The rows above came from these meters. Use the same `serviceName` and match on `productName` and `meterName`.

| Rows | `serviceName` | `productName` / `meterName` |
|---|---|---|
| 1-3 | Azure App Service | `Azure App Service Basic Plan - Linux` / `B1`; `Azure App Service Standard Plan - Linux` / `S1 App`; `Azure App Service Premium v3 Plan - Linux` / `P1 v3 App` |
| 5 | Azure Database for MySQL | `Azure Database for MySQL Flexible Server Burstable BS Series Compute` / `B2S` |
| 6 | Azure Database for MySQL | `Azure Database for MySQL Flexible Server General Purpose Series Compute` / `vCore` |
| 7-9 | Azure Database for MySQL | `Azure Database for MySQL Flexible Server Storage` / `Storage Data Stored`, `Additional IOPS`; `Azure Database for MySQL Flexible Server Backup Storage` / `Backup Storage LRS Data Stored` |
| 10 | Azure DNS | `Azure DNS` / `Private Zone` |
| 12 | Storage | `General Block Blob v2` / `Hot LRS Data Stored`, `Hot LRS Write Operations`, `Hot Read Operations` |
| 13 | Key Vault | `Key Vault` / `Operations` (sku `Standard`) |
| 14 | Log Analytics | `Log Analytics` / `Analytics Logs Data Ingestion`, `Analytics Logs Data Retention` |
| 15-17 | Azure Monitor | `Alerts Metric Monitored`; `Alerts System Log Monitored at 5 Minute Frequency`; `Standard Web Test Execution` |
| 18-19 | Azure Front Door Service | `Standard Base Fees`; `Premium Base Fees` |

## Verify

**Who:** operator. **STOP:** no.

After a full month, compare the table with **Cost Management → Cost analysis** for the site's resource groups,
grouped by meter. If a figure differs by more than rounding, re-run step 3 and update this page.

## Rollback

Not applicable. This page changes nothing in Azure.

## References

- [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
- [App Service pricing (Linux)](https://azure.microsoft.com/en-us/pricing/details/app-service/linux/)
- [Azure Database for MySQL Flexible Server pricing](https://azure.microsoft.com/en-us/pricing/details/mysql/flexible-server/)
- [Azure Monitor pricing](https://azure.microsoft.com/en-us/pricing/details/monitor/)
- [Azure Front Door pricing](https://azure.microsoft.com/en-us/pricing/details/frontdoor/)
- [Azure DNS pricing](https://azure.microsoft.com/en-us/pricing/details/dns/)
- [Storage IOPS in Azure Database for MySQL Flexible Server](https://learn.microsoft.com/en-us/azure/mysql/flexible-server/concepts-service-tiers-storage)
- [Set up staging environments in Azure App Service](https://learn.microsoft.com/en-us/azure/app-service/deploy-staging-slots)
