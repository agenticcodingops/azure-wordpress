# Architecture decision records

These records describe accepted design choices in the module. Code references are line numbers at commit `0ca9c63afe42ba866bc0a9b748946448a699da2b`; each record repeats that commit so a future reader can resolve the cited lines.

| Number | Decision | Summary |
| --- | --- | --- |
| 0001 | [Two-layer model and early Application Insights](0001-two-layer-model-and-early-application-insights.md) | Separate foundation and application layers, with telemetry created between them. |
| 0002 | [Monitoring is inline in the composition module](0002-inline-monitoring-in-composition.md) | Let the composition own the early monitoring dependency. |
| 0003 | [Environment-aware defaults omit optional defaults](0003-environment-aware-defaults.md) | Preserve null until locals select the environment-specific value. |
| 0004 | [Security settings use flat top-level variables](0004-flat-security-variables.md) | Keep security controls visible to static analysis. |
| 0005 | [Key Vault uses access policies instead of RBAC](0005-key-vault-access-policies.md) | Grant secret permissions with explicit access policies. |
| 0006 | [Do not mount Azure Files](0006-no-azure-files-mount.md) | Use persistent `/home` and optional Blob offload without a file-share mount. |
| 0007 | [Use one cdn_provider switch](0007-single-cdn-provider-switch.md) | Select one mutually exclusive edge path. |
| 0008 | [Inject the Front Door profile ID after creation](0008-inject-front-door-profile-id-after-creation.md) | Patch the profile-specific origin restriction after both resources exist. |
| 0009 | [Read the deployer identity outside depends_on](0009-read-deployer-identity-outside-depends-on.md) | Keep access-policy identity values known during planning. |
| 0010 | [Offer CanNotDelete-only locks](0010-cannotdelete-only-locks.md) | Prevent deletion without the management problems of ReadOnly locks. |
| 0011 | [Default to a floating image tag](0011-floating-image-tag-default.md) | Follow the supported container series unless an adopter assumes patch ownership. |
| 0012 | [Prefer Azure Verified Modules](0012-azure-verified-modules-first.md) | Prefer compatible verified modules and otherwise retain their interface shapes. |

## Evidence

The short excerpts below are the exact text that supports each record's claim. Absence is not used as evidence: record 0006 pairs the configured site block with the architecture document's explicit statement that there is no mount.

| Record | Citation | Exact text cited | Claim supported |
| --- | --- | --- | --- |
| 0001 | `modules/wordpress-site/main.tf:326-368` | `LAYER 1: FOUNDATION`; `EARLY MONITORING RESOURCES (BREAKS CIRCULAR DEPENDENCY)` | The foundation layer precedes early monitoring. |
| 0001 | `modules/wordpress-site/main.tf:395-399` | `LAYER 2: APPLICATION`; `depends_on ensures Layer 1 → Layer 2 ordering` | The application layer explicitly follows Layer 1. |
| 0001 | `modules/wordpress-site/main.tf:511-516` | `"appinsights-connection" = azurerm_application_insights.main.connection_string` | The early component supplies a Key Vault secret. |
| 0002 | `modules/wordpress-site/main.tf:364-393` | `resource "azurerm_application_insights" "main"` | The composition creates monitoring inline. |
| 0002 | `modules/wordpress-site/main.tf:520-572` | `azurerm_application_insights.main` | Key Vault depends on the inline component. |
| 0003 | `modules/wordpress-site/variables.tf:80-96` | `giving them an optional() default here would mean null never reaches that coalesce` | Environment-aware attributes omit defaults intentionally. |
| 0003 | `modules/wordpress-site/main.tf:96-103` | `backup_retention_days = coalesce(var.database.backup_retention_days, var.environment == "production" ? 30 : 7)` | The local selects a value by environment. |
| 0004 | `modules/wordpress-site/variables.tf:706-713` | `static analysers cannot see through optional() object attributes` | Scanner visibility motivates flat inputs. |
| 0004 | `modules/wordpress-site/variables.tf:107-110` | `four stage flags are flat top-level bools` | Security stage switches follow the flat pattern. |
| 0005 | `modules/key-vault/main.tf:41-47` | `rbac_authorization_enabled = false # Use access policies` | Key Vault RBAC is disabled. |
| 0005 | `modules/key-vault/main.tf:70-99` | `resource "azurerm_key_vault_access_policy" "app_service"`; `resource "azurerm_key_vault_access_policy" "terraform"` | Explicit policies serve the two principals. |
| 0006 | `modules/app-service/main.tf:231-245` | `application_stack`; `docker_image_name = "appsvc/wordpress-debian-php:${var.docker_image_tag}"` | The configured site block contains the container configuration. |
| 0006 | `docs/architecture.md:388-393` | `there is no Azure Files mount either way` | The lack of an Azure Files mount is explicit. |
| 0007 | `modules/wordpress-site/variables.tf:531-540` | `contains(["cloudflare", "azure_front_door", "direct"], var.cdn_provider)` | One validated switch has three choices. |
| 0007 | `modules/wordpress-site/main.tf:182-197` | `var.cdn_provider == "azure_front_door"`; `var.cdn_provider == "cloudflare"` | The same switch gates both CDN paths. |
| 0008 | `modules/wordpress-site/main.tf:644-647` | `front_door_id is NOT passed here to avoid circular dependency` | The initial app construction omits the profile ID. |
| 0008 | `modules/wordpress-site/main.tf:1012-1036` | `x-azure-fdid = [module.front_door[0].resource_guid]` | The later patch injects the created profile GUID. |
| 0009 | `modules/wordpress-site/main.tf:66-74` | `data "azurerm_client_config" "current" {}`; `deployer_object_id = ...` | The composition reads and resolves the identity. |
| 0009 | `modules/wordpress-site/main.tf:533-571` | `outside this module's depends_on`; `deployer_object_id = local.deployer_object_id` | Known IDs are passed into the dependent module. |
| 0010 | `modules/shared-infrastructure/variables.tf:84-99` | `Only kind = "CanNotDelete" is accepted`; `ReadOnly is not offered` | The lock interface excludes ReadOnly. |
| 0010 | `modules/wordpress-site/main.tf:1187-1197` | `lock_level = local.site_lock.kind` | The selected CanNotDelete lock is applied to the site group. |
| 0011 | `modules/wordpress-site/variables.tf:74-77` | `default = "8.3"` | The composition defaults to a floating tag. |
| 0011 | `modules/wordpress-site/main.tf:606` | `docker_image_tag = var.wordpress_version` | The input is forwarded as an image tag. |
| 0011 | `modules/app-service/main.tf:241-245` | `docker_image_name = "appsvc/wordpress-debian-php:${var.docker_image_tag}"` | App Service deploys the selected tag. |
| 0012 | `AGENTS.md:80-86` | `Azure Verified Modules first`; `Check its version constraints first` | The convention requires compatible verified modules first. |
| 0012 | `modules/shared-infrastructure/variables.tf:84-91` | `Resource lock in the Azure Verified Modules lock shape` | The lock interface follows the verified-module shape. |
| 0012 | `modules/wordpress-site/variables.tf:706-711` | `type follows the Azure Verified Modules diagnostic_settings interface` | Diagnostic inputs follow that interface within provider limits. |
