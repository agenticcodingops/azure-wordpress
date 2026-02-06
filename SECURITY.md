# Security Policy

## Supported Versions

The following versions of azure-wordpress are currently supported with security updates:

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |
| < 1.0   | :x:                |

## Reporting a Vulnerability

We take security issues seriously. If you discover a security vulnerability in azure-wordpress, please report it responsibly.

### How to Report

**Please do NOT report security vulnerabilities through public GitHub issues.**

Instead, report vulnerabilities via one of these methods:

1. **GitHub Security Advisories** (Preferred): Use [GitHub's private vulnerability reporting](https://github.com/agenticcodingops/azure-wordpress/security/advisories/new)

2. **Email**: Send details to **hassan.abbas@agenticcodingops.com**

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

When using azure-wordpress, follow these security recommendations:

### Secrets Management

- **Never commit secrets** to version control
- Use **Azure Key Vault** for all sensitive values (enabled by default)
- Use **environment variables** or **terraform.tfvars** (gitignored) for provider credentials
- Enable **Managed Identity** authentication where possible

### Network Security

- Keep **private endpoints enabled** for MySQL (default configuration)
- Use **Cloudflare proxy** or **Azure Front Door WAF** to protect origin
- Restrict App Service access to CDN IPs only when using Cloudflare
- Enable **TLS 1.2 minimum** (enforced by default)

### Access Control

- Follow **least privilege** principles for Azure RBAC
- Use **separate service principals** for different environments
- Enable **Azure AD authentication** for administrative access
- Regularly rotate credentials and access keys

### State File Security

- Store Terraform state in **Azure Storage with encryption**
- Enable **state file locking** using Azure Blob lease
- Restrict access to state storage account
- Consider using **Terraform Cloud** or **Azure DevOps** for state management

### Monitoring

- Enable **Application Insights** for runtime monitoring
- Configure **Azure Security Center** for threat detection
- Set up **alerts** for suspicious activities
- Regularly review **Azure Activity Logs**

### Example Secure Backend Configuration

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "tfstate-rg"
    storage_account_name = "tfstatestorage"
    container_name       = "tfstate"
    key                  = "wordpress.tfstate"
    use_azuread_auth     = true
  }
}
```

## Security Updates

Security updates are released as patch versions. Subscribe to:

- [GitHub Releases](https://github.com/agenticcodingops/azure-wordpress/releases) for notifications
- [GitHub Security Advisories](https://github.com/agenticcodingops/azure-wordpress/security/advisories) for vulnerability alerts

## Acknowledgments

We appreciate the security research community's efforts in responsibly disclosing vulnerabilities. Contributors who report valid security issues will be acknowledged in our security advisories.
