# Contributing to azure-wordpress

Thank you for your interest in contributing to azure-wordpress! This document provides guidelines and instructions for contributing.

## Code of Conduct

This project adheres to the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code.

## How to Contribute

### Reporting Issues

- Check existing issues to avoid duplicates
- Use the appropriate issue template (bug report or feature request)
- Provide as much detail as possible

### Fork and Clone Workflow

1. Fork the repository on GitHub
2. Clone your fork locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/azure-wordpress.git
   cd azure-wordpress
   ```
3. Add the upstream remote:
   ```bash
   git remote add upstream https://github.com/agenticcodingops/azure-wordpress.git
   ```
4. Keep your fork up to date:
   ```bash
   git fetch upstream
   git checkout main
   git merge upstream/main
   ```

### Branch Naming Convention

Use the following prefixes for your branches:

- `feature/*` - New features or enhancements
- `fix/*` - Bug fixes
- `docs/*` - Documentation changes
- `refactor/*` - Code refactoring
- `test/*` - Test additions or modifications

Examples:
```bash
git checkout -b feature/add-redis-cache
git checkout -b fix/mysql-connection-timeout
git checkout -b docs/update-readme
```

### Development Setup

1. Install required tools:
   - [OpenTofu](https://opentofu.org/) >= 1.6.0 or [Terraform](https://www.terraform.io/) >= 1.6.0
   - [tfsec](https://github.com/aquasecurity/tfsec)
   - [checkov](https://www.checkov.io/)
   - [terraform-docs](https://terraform-docs.io/)

2. Configure pre-commit hooks (recommended):
   ```bash
   pre-commit install
   ```

### Terraform Formatting Requirements

All Terraform code must be properly formatted:

```bash
# Format all files
tofu fmt -recursive

# Check formatting without making changes
tofu fmt -recursive -check
```

### Testing Requirements

Before submitting a PR, ensure all checks pass:

```bash
# Validate Terraform configuration
tofu init -backend=false
tofu validate

# Run security scans
tfsec .
checkov -d .

# Generate documentation (if module outputs changed)
terraform-docs markdown table --output-file README.md ./modules/YOUR_MODULE
```

### Commit Message Format

This project follows [Conventional Commits](https://www.conventionalcommits.org/). Each commit message should be structured as:

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

**Types:**
- `feat` - New feature
- `fix` - Bug fix
- `docs` - Documentation only changes
- `style` - Formatting, missing semicolons, etc.
- `refactor` - Code change that neither fixes a bug nor adds a feature
- `test` - Adding or updating tests
- `chore` - Maintenance tasks

**Examples:**
```
feat(cloudflare): add support for custom page rules

fix(database): correct private endpoint subnet association

docs(readme): update architecture diagram

refactor(app-service): simplify identity configuration
```

### Pull Request Process

1. **Create a PR** against the `main` branch
2. **Fill out the PR template** completely
3. **Ensure all checks pass:**
   - `tofu fmt` - Code is formatted
   - `tofu validate` - Configuration is valid
   - `tfsec` - No security issues
   - `checkov` - Compliance checks pass
4. **Update documentation** if you changed module inputs/outputs
5. **Request review** from maintainers

### PR Review Guidelines

Reviewers will check for:

- Code quality and readability
- Adherence to Terraform best practices
- Proper variable naming and descriptions
- Complete documentation for new features
- Test coverage for new functionality
- No hardcoded values (use variables)
- Proper use of data sources vs resources

### Style Guide

- Use descriptive variable names with clear descriptions
- Group related resources together
- Use `locals` for computed values
- Prefer `for_each` over `count` when possible
- Add validation blocks for variables where appropriate
- Use consistent naming: `snake_case` for resources, `kebab-case` for Azure resource names

## Getting Help

- Open a [Discussion](https://github.com/agenticcodingops/azure-wordpress/discussions) for questions
- Join our community chat (if available)
- Review existing issues and PRs for context

## Recognition

Contributors will be recognized in the project's release notes. Thank you for helping improve azure-wordpress!
