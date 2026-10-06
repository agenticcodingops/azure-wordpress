# Code Review Style Guide & Guidelines for Gemini Code Assist

This style guide establishes the standards, architectural patterns, and review expectations
for automated reviews performed on the `azure-wordpress` repository.

---

## 1. Project Context & Technology Stack Summary

- **Domain**: Production-grade, highly available WordPress infrastructure deployment on Microsoft Azure using Infrastructure-as-Code (IaC).
- **Primary Languages & Frameworks**: HashiCorp Terraform / OpenTofu (pinned to Terraform `1.9.8`), targeting `azurerm` (`~> 5.6`) and `azapi` providers.
- **Workload Container**: WordPress on Azure App Service using `mcr.microsoft.com/appsvc/wordpress-debian-php`.
- **Supporting Scripts**: Python 3 (`scripts/*.py`), POSIX Shell (`scripts/*.sh`, `.githooks/*.sh`), and PowerShell (`scripts/*.ps1`).
- **Static Analysis & Linters**:
  - `terraform fmt -recursive` / `tofu fmt -recursive`
  - `terraform validate` across all modules
  - `trivy` (secret scanning and IaC misconfiguration)
  - `checkov` (IaC compliance, pinned rules in `validate.yml`)
  - `tflint`
  - `terraform-docs` (v0.20.0, required for all module READMEs)

---

## 2. Architecture & Directory Hierarchy

The repository follows a two-layer modular architecture orchestrated by a single composition module:

```text
Layer 1 (Foundation):  modules/networking → modules/dns-zones
Layer 2 (Application): modules/database, modules/storage, modules/key-vault → modules/app-service → modules/front-door / modules/cloudflare
```

- **Composition Module (`modules/wordpress-site`)**:
  - Acts as the entrypoint for consumers. Accepts high-level configuration objects (`database = {}`, `storage = {}`, `app_service = {}`).
  - Sets **environment-aware defaults** for `prod` (production) and `np` (non-production).
- **Sub-modules (`modules/<name>`)**:
  - 10 focused sub-modules: `app-service`, `cloudflare`, `database`, `dns-zones`, `front-door`, `key-vault`, `monitoring`, `networking`, `shared-infrastructure`, `storage`.
  - Sub-modules must not hardcode environment defaults (which are resolved by the composition module), but they may enforce production safety invariants (such as the database module's `enforce_production_sku` check).
- **Dependency Flow & Circular Dependency Handling**:
  - Application Insights is provisioned between layers so its connection string is written to Key Vault before App Service is provisioned.
  - Front Door uses `azapi_update_resource` to inject the Front Door ID into App Service IP restrictions post-creation.

---

## 3. Strict Review Standards

Gemini Code Assist must evaluate pull requests against the following criteria:

### A. Security Standards (Critical / High Priority)
1. **Zero Secret Leakage**:
   - Never allow hardcoded credentials, connection strings, API tokens, or plain-text passwords in code, default variable values, or documentation examples.
   - Database passwords must be generated via `random_password` and stored directly into Azure Key Vault.
2. **Key Vault References**:
   - App Service settings must reference secrets via `@Microsoft.KeyVault(SecretUri=...)` or `@Microsoft.KeyVault(VaultName=...;SecretName=...)`.
   - Never pass raw passwords as plain-text App Settings or environment variables.
3. **Identity & Access Management (IAM)**:
   - Use Managed Identities (System-Assigned or User-Assigned) for App Service and staging slots.
   - Enforce least-privilege RBAC role assignments.
4. **Network Isolation & Transport Security**:
   - Storage accounts must enforce `min_tls_version = "TLS1_2"` and `https_traffic_only_enabled = true`. Public access should be restricted via virtual network rules or private endpoints.
   - Linux web apps must enforce `https_only = true` and `site_config.minimum_tls_version = "1.2"`.
   - MySQL Flexible Server explicitly sets `require_secure_transport = "OFF"` (`modules/database/main.tf:91-96`) because the official WordPress container does not configure client-side MySQL TLS certificates by default, relying instead on network-layer encryption over the delegated subnet. Do not flag this parameter as a vulnerability in isolation.

### B. Terraform Expression Safety & Null / Undefined Safety
1. **Environment-Aware Defaults Pattern**:
   - In `modules/wordpress-site`, optional object attributes that receive environment-aware defaults must be declared as `optional(<type>)` **without** a default fallback (i.e. NOT `optional(number, 7)`).
   - If an attribute carries a default in the type signature, `null` never reaches `coalesce()` in locals, rendering environment branches unreachable. Flag any violation of this pattern.
2. **Staging Slot Detection**:
   - Staging slots must only be provisioned on Standard (`S*`) and Premium (`P*`) SKUs.
   - Detection must use an allow-list regex: `can(regex("^(S|P)[0-9]", var.sku_name))` so unsupported tiers (e.g. Free `F1`, Shared `D1`) fail closed safely.
3. **Container Environment Variables**:
   - The WordPress container (`mcr.microsoft.com/appsvc/wordpress-debian-php`) expects:
     - `DATABASE_HOST`, `DATABASE_NAME`, `DATABASE_USERNAME`, `DATABASE_PASSWORD`.
   - Flag any usage of standard generic names (`WORDPRESS_DB_*`) as broken.
4. **Guarded Lookups**:
   - Use `try()` and `can()` for dynamic attributes or conditional resource lookups to prevent plan/apply crashes.

### C. Resource Lifecycle & Destructive Actions
1. **Destructive Changes**:
   - Explicitly warn if a change would cause resource replacement/destruction of stateful resources (databases, storage accounts, key vaults).
   - Check resource identifiers, subnet delegations, and SKU alterations for breaking drift.
2. **Azure Verified Modules (AVM) Pattern**:
   - When new Azure resources are added, prefer Azure Verified Modules where available.
   - Standard resource variables must adhere to AVM interface standards: `lock`, `diagnostic_settings`, `role_assignments`, `managed_identities`, `tags`.
   - Every module must declare a `required_providers` block with explicit upper and lower version bounds.

### D. Compliance & Linting Standards
1. **Checkov Skip Formatting**:
   - Checkov suppression lists must use a single comma-separated string without spaces (e.g., `skip_check: CKV_TF_1,CKV_TF_2`).
   - Never use YAML folded scalar syntax (`>-`).
2. **Documentation Parity**:
   - Any modification to variables, outputs, or resources in a module must be reflected in that module's `README.md` between `<!-- BEGIN_TF_DOCS -->` and `<!-- END_TF_DOCS -->`.

---

## 4. Forbidden Patterns

Flag any of the following anti-patterns immediately:

| Anti-Pattern | Reason / Correct Pattern |
|---|---|
| Hardcoded secrets or credentials | Use `random_password` + Azure Key Vault + App Service Key Vault references. |
| `optional(type, default_val)` on environment-dependent inputs | Prevents `coalesce()` from applying prod/nonprod defaults. Use `optional(type)` without default. |
| Using `WORDPRESS_DB_*` env vars | Azure WordPress container requires `DATABASE_*` naming. |
| Open access (`0.0.0.0/0`) on MySQL or Storage firewalls | Restrict to App Service outbound IPs or VNet integration subnets. |
| Unpinned provider versions or modules | Always declare upper bounds in `required_providers`. |
| Unbounded resource names exceeding Azure character limits | Follow naming convention `{type}-{project}-{site}-{env}` (Storage accounts: 3-24 lowercase alphanumeric). |
| Vendor/tool branding in commit metadata | Version control metadata policy (AGENTS.md) strictly forbids tool/vendor names in commit messages, trailers, and PR text. |

---

## 5. Tone & Output Rules

To maintain high reviewer signal and avoid contributor friction:

1. **Concise and Actionable**:
   - State the issue clearly in 1–2 sentences.
   - Explain the risk (e.g., security vulnerability, resource destruction, plan failure).
2. **Provide Inline Diffs**:
   - Whenever proposing a code fix, use GitHub Markdown suggestion blocks:
     ````markdown
     ```suggestion
     <corrected code>
     ```
     ````
3. **Prioritize Blocking vs. Non-Blocking**:
   - Prefix comments with clear severity indicators:
     - `[BLOCKING]`: Security flaw, syntax error, breaking API change, or resource destruction.
     - `[WARNING]`: Sub-optimal pattern, missing documentation update, or performance concern.
     - `[SUGGESTION]`: Minor improvement or optimization opportunity.
4. **Avoid Nitpicking**:
   - Do not comment on purely subjective style preferences that are already enforced by `terraform fmt`.
   - Focus on correctness, reliability, security, and architectural alignment.
