# Security Policy

## Supported Versions

The following versions of azure-wordpress are currently supported with security updates:

| Version | Supported          |
| ------- | ------------------ |
| 4.x     | :white_check_mark: |
| < 4.0   | :x:                |

## Reporting a Vulnerability

We take security issues seriously. If you discover a security vulnerability in azure-wordpress, please report it responsibly.

### How to Report

**Please do NOT report security vulnerabilities through public GitHub issues.**

Instead, report vulnerabilities via one of these methods:

1. **GitHub private vulnerability reporting** (Preferred): Use the
   [Report a vulnerability form](https://github.com/agenticcodingops/azure-wordpress/security/advisories/new)

2. **Email** (if the form is unavailable to you): Send details to **hassan.abbas@agenticcodingops.com**

### What to Include

Please include the following information in your report:

- Description of the vulnerability
- Steps to reproduce the issue
- Affected module(s) and version(s)
- Potential impact
- Any suggested fixes (optional)

### Response Timeline

- **Initial Response**: Within 48 hours
- **Status Update**: Within 7 days
- **Resolution Target**: Within 30 days for critical issues

### What to Expect

1. We will acknowledge receipt of your report
2. We will investigate and validate the issue
3. We will work on a fix and coordinate disclosure
4. You will be credited in the security advisory (unless you prefer anonymity)

## Security Best Practices for Users

When using azure-wordpress, follow these security recommendations. The
[security model](docs/security-model.md) explains what the module enforces, what it leaves
to you, and the code behind each control.

### Secrets Management

- **Never commit secrets** to version control
- Use **Azure Key Vault** for all sensitive values (enabled by default)
- Authenticate the `azurerm` provider without a stored secret: use OpenID Connect (workload identity federation)
  in CI, as in [step 2 of the deployment guide](docs/deployment-guide.md#step-2-create-the-ci-identities). Where a
  provider needs a secret, such as the Cloudflare API token, prefer the provider's own environment variable
  (`CLOUDFLARE_API_TOKEN`, or `ARM_CLIENT_SECRET` only if OIDC is not possible) over a Terraform variable. A value
  set through `terraform.tfvars`, a `TF_VAR_` variable or `-var` is stored in clear text in every saved plan file:
  keep `terraform.tfvars` out of version control and treat saved plans like state
- Enable **Managed Identity** authentication where possible

### Network Security

- Keep MySQL on its **delegated subnet** (private access, the only mode the module deploys). The server has no
  public endpoint and is reached only from the virtual network. The module does not create a private endpoint
  for it
- Put a CDN in front of the origin: set `cdn_provider` to `"cloudflare"` or `"azure_front_door"`, and the module
  admits only that CDN's address ranges at the origin. Cloudflare's ranges are shared by every Cloudflare account,
  so they admit Cloudflare and not only your zone. With `front_door.enabled` true (the default), Front Door is bound to your profile by `X-Azure-FDID` on the main
  app only; with it false, any Front Door profile is admitted (see
  [Binding the origin to one CDN account](docs/security-model.md#binding-the-origin-to-one-cdn-account)). The default, `"direct"`, leaves the origin open to everyone. The restriction
  takes effect in the apply that sets `cdn_provider`, whether or not DNS sends visitors through the CDN yet, and App
  Service answers every other request with HTTP 403. On a live site:
  - With Cloudflare, proxy the site's DNS record through Cloudflare **before** that apply. The open origin admits
    Cloudflare in the meantime. `cloudflare.enabled = true` makes the module create the site's records, but
    Cloudflare refuses a CNAME whose name an existing A, AAAA or CNAME record already uses, so import existing
    records first. With the default, `false`, the module creates no DNS records.
  - With Front Door, the CNAME target and the `_dnsauth` TXT value are outputs of that same apply
    (`front_door_endpoint_hostname`, `custom_domain_validation_token`). Schedule a maintenance window: the site is
    unreachable until the domain validates, its managed certificate is issued and DNS points at Front Door.
  - A site served on its own `*.azurewebsites.net` name has no DNS to move. Give it a custom domain you control
    first.

  See [Request flow: Cloudflare](docs/architecture.md#request-flow-cloudflare) and
  [Request flow: Azure Front Door](docs/architecture.md#request-flow-azure-front-door)
- Restrict the **SCM (Kudu) endpoint**, which is open by default. Add every address you use Kudu from to
  `app_service_scm_ip_restrictions`, then set `app_service_scm_ip_restriction_default_action = "Deny"`. A `Deny`
  with no allow rule that covers you also cuts off the Kudu SSH console, which is how you run WP-CLI in the
  container. Terraform is unaffected, because it manages the app through the Azure Resource Manager control plane.
  Read [Hardening the SCM/Kudu endpoint](modules/wordpress-site/README.md#hardening-the-scmkudu-endpoint) first
- **TLS 1.2 minimum** is enforced on the web app, the storage account and the Front Door custom domain. MySQL
  does not require TLS: the module sets `require_secure_transport = OFF`
- See [docs/architecture.md](docs/architecture.md#network) for the network design, and the
  [security model](docs/security-model.md) for what the module enforces and what it leaves to you

### Access Control

- Follow **least privilege** principles for Azure RBAC
- Use **separate service principals** for different environments
- Enable **Microsoft Entra ID authentication** for administrative access
- Rotate your own credentials (CI identities, operator accounts) regularly. The module has no tested rotation
  procedure for the secrets it generates (database password, storage account key, Application Insights connection
  string). Read the [rotation warning](docs/security-model.md#how-to-protect-state) before you try: replacing the
  generated database password through Terraform breaks the site

### State File Security

- Terraform state holds the generated database password, the storage account key and
  other secrets **in plain text**. Treat read access to state as access to those secrets.
  See [Terraform state](docs/security-model.md#terraform-state-holds-generated-secrets).
- Store Terraform state in **Azure Storage with encryption**
- Authenticate the backend with **Microsoft Entra ID** (`use_azuread_auth = true`)
- The `azurerm` backend **locks state** automatically, using Azure Blob Storage
- Restrict access to state storage account
- Consider a managed state service such as **HCP Terraform** (formerly Terraform Cloud)

### Monitoring

- Enable **Application Insights** for runtime monitoring
- Configure **Microsoft Defender for Cloud** for threat detection
- Set up **alerts** for suspicious activities
- Regularly review **Azure Activity Logs**

### Backend configuration

Keep state in Azure Storage, with one container per environment and Microsoft Entra ID authentication
(`use_azuread_auth = true`). Give each deployment identity a data role on its own container only.
[Step 1 of the deployment guide](docs/deployment-guide.md#step-1-create-the-state-store) creates the store, and
[Getting started](docs/getting-started.md#the-configuration) shows the `backend.hcl`.

## Security Updates

Security updates are released as patch versions. Subscribe to:

- [GitHub Releases](https://github.com/agenticcodingops/azure-wordpress/releases) for notifications
- [GitHub Security Advisories](https://github.com/agenticcodingops/azure-wordpress/security/advisories) for vulnerability alerts

## Acknowledgments

We appreciate the security research community's efforts in responsibly disclosing vulnerabilities. Contributors who report valid security issues will be acknowledged in our security advisories.
