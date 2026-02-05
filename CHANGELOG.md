# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2024-01-15

### Added

- Initial release of terraform-azure-wordpress

#### Core Modules
- **wordpress-site** - Complete WordPress deployment composition module
- **shared-infrastructure** - Shared App Service Plan for multi-site deployments
- **app-service** - Azure App Service (Linux) with managed WordPress container
- **database** - Azure MySQL Flexible Server with Private Endpoint
- **storage** - Azure Blob Storage for WordPress media uploads
- **key-vault** - Azure Key Vault for secrets management with managed identity
- **networking** - Virtual Network and subnet configuration
- **dns-zones** - Private DNS zones for internal resolution
- **monitoring** - Application Insights and alerting configuration

#### CDN Modules
- **cloudflare** - Cloudflare DNS, CDN, and WAF integration
- **front-door** - Azure Front Door CDN with WAF (enterprise option)

#### Features
- Multi-site deployment on shared App Service Plans for cost optimization
- Private endpoint connectivity for MySQL database
- Managed identity authentication (no credentials in code)
- Key Vault references for runtime secret injection
- Cloudflare IP restriction for origin protection
- TLS 1.2 minimum enforcement across all services
- Comprehensive monitoring with Application Insights
- Support for custom domains with automated SSL

#### Documentation
- Complete module documentation with examples
- Architecture diagrams (text and Mermaid)
- Cost optimization guide
- CDN comparison matrix

[Unreleased]: https://github.com/agenticcodingops/terraform-azure-wordpress/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/agenticcodingops/terraform-azure-wordpress/releases/tag/v1.0.0
