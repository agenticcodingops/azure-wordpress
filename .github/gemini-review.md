# Gemini Code Assist Review Guidelines (.github/gemini-review.md)

This file defines the automated code review policies, operational guidelines, and domain standards
for Gemini Code Assist on pull requests in the `azure-wordpress` repository.

> Note: The Gemini Code Assist GitHub App automatically reads repository configuration from
> `.gemini/config.yaml` and `.gemini/styleguide.md`. This file provides the complete guideline specification
> and serves as the primary reference within `.github/`.

---

## 1. Project Context & Technology Stack Summary

- **Repository**: `azure-wordpress` (Infrastructure-as-Code for enterprise WordPress on Azure).
- **Primary Languages**: HashiCorp Terraform / OpenTofu (pinned to Terraform `1.9.8`).
- **Target Providers**: `hashicorp/azurerm` (`~> 5.6`), `azure/azapi`, `hashicorp/random`.
- **Workload**: Containerized WordPress (`mcr.microsoft.com/appsvc/wordpress-debian-php`) running on Linux Azure App Service.
- **Architecture**: Two-layer modular composition model:
  - **Composition**: `modules/wordpress-site` (orchestrates 10 sub-modules with environment-aware defaults).
  - **Foundation (Layer 1)**: `modules/networking` → `modules/dns-zones`.
  - **Application (Layer 2)**: `modules/database`, `modules/storage`, `modules/key-vault` → `modules/app-service` → `modules/front-door` / `modules/cloudflare`.
  - **Monitoring**: Application Insights connection string created before App Service to eliminate circular dependencies.
- **Quality & Security Pipeline**:
  - Format: `tofu fmt -recursive` / `terraform fmt -recursive`
  - Validation: `terraform validate`
  - Static Security & IaC: `trivy`, `checkov`, `tflint`, `gitleaks`
  - Documentation: `terraform-docs` (0.20.0, fail-on-diff enforced in CI)

---

## 2. Review Standards & Focus Areas

### Security & Compliance (Highest Priority)
- **Zero Credentials in Code**: Reject any hardcoded passwords, tokens, API keys, or connection strings.
- **Key Vault Integration**: Passwords must be generated dynamically (`random_password`) and stored in Azure Key Vault. App Service must reference secrets via `@Microsoft.KeyVault(...)`.
- **Network Boundaries**: Ensure MySQL Flexible Server, Storage Accounts, and Key Vault restrict public network access. Validate that firewall rules and VNet service endpoints/private endpoints are correctly wired.
- **Least Privilege**: Managed Identities (System-Assigned or User-Assigned) must be used for service-to-service authentication with minimal necessary RBAC roles.
- **Transport Security**: Verify `min_tls_version = "TLS1_2"` and `https_traffic_only_enabled = true` on storage accounts. Verify `https_only = true` and `site_config.minimum_tls_version = "1.2"` on Linux web apps. Note that MySQL Flexible Server sets `require_secure_transport = "OFF"` (`modules/database/main.tf:91-96`) by design because the WordPress container lacks client-side TLS certificates and relies on delegated subnet private network security.

### Edge Cases, Null Safety & Error Handling
- **Environment-Aware Defaults in Composition Module**:
  - Optional attributes in `modules/wordpress-site` variables that rely on environment defaults (`prod` vs `np`) must NOT define a default value inside `optional()` (e.g., use `optional(number)` NOT `optional(number, 7)`).
  - Defining a default inside `optional()` causes `coalesce()` in locals to never see `null`, breaking environment selection.
- **Staging Slot Guard**:
  - Azure App Service deployment slots are only available on Standard and Premium tiers.
  - Verify detection uses: `can(regex("^(S|P)[0-9]", var.sku_name))` so unsupported tiers fail closed.
- **Container Environment Variables**:
  - The container requires `DATABASE_HOST`, `DATABASE_NAME`, `DATABASE_USERNAME`, `DATABASE_PASSWORD`.
  - Flag any accidental use of standard WordPress env vars (`WORDPRESS_DB_*`).
- **Dynamic Lookups**:
  - Expressions that inspect optional map/object keys must be guarded with `try()` or `can()` to avoid runtime plan failures.

### Performance, Cost & Resource Lifecycle
- **Resource Replacement**: Flag any change that forces resource recreation (`Forces replacement`), particularly on stateful resources (database servers, storage accounts, key vaults).
- **SKU & Retention Tuning**: Ensure non-production environments use cost-effective SKUs and lower retention periods (7 days vs 30/90 days in prod).
- **Checkov Skip List Format**: Ensure any Checkov suppression matches the required single comma-separated format without spaces: `skip_check: CKV_TF_1,CKV_TF_2`.

---

## 3. Forbidden Patterns

Flag any pull request introducing the following:
1. **Hardcoded secrets or database credentials**.
2. **`optional(type, default)` on environment-branched locals** in `modules/wordpress-site`.
3. **`WORDPRESS_DB_*` container variables** instead of `DATABASE_*`.
4. **Permissive firewall rules** (`0.0.0.0/0` or `*`) on backend databases or storage.
5. **Missing version pins** in `required_providers`.
6. **YAML folded scalar (`>-`) in Checkov skip lists**.
7. **Modifying module inputs/outputs without updating module README documentation** via `terraform-docs`.

---

## 4. Tone, Formatting & Output Rules

- **Be Concise and Actionable**: Keep review remarks direct, focused on the specific line diff, and limited to 1–3 clear sentences.
- **Provide Inline Suggestion Diffs**: Whenever suggesting a code change, format it as an actionable GitHub suggestion:
  ````markdown
  ```suggestion
  <replacement code>
  ```
  ````
- **Classify Comments by Severity**:
  - `[BLOCKING]`: Critical security risk, resource replacement/destruction, circular dependency, or syntax failure.
  - `[WARNING]`: Architectural deviation, edge case vulnerability, or missing docs.
  - `[SUGGESTION]`: Minor improvement or optimization.
- **Highlight Breaking Changes**: Explicitly point out any change to input variables, output contracts, or provider requirements that could impact downstream consumers.
- **Do Not Nitpick**: Avoid stylistic debates covered by automated tools (`terraform fmt`).

---

## 5. Team Slash Commands

Team members can trigger Gemini Code Assist directly in GitHub PR comments using:
- `/gemini review` — Request a full automated code review on the latest commit.
- `/gemini summary` — Generate a high-level summary of changes in the PR.
- `/gemini help` — Display available commands and interaction options.
- `@gemini-code-assist <question>` — Ask specific questions or request targeted feedback on a code block.
