## Description

<!-- Describe your changes in detail -->

## Type of Change

<!-- Mark the relevant option with an 'x' -->

- [ ] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature (non-breaking change that adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to change)
- [ ] Documentation update
- [ ] Refactoring (no functional changes)

## Related Issues

<!-- Link any related issues using #issue_number -->

Fixes #

## Modules Affected

<!-- List the modules affected by this change -->

- [ ] wordpress-site
- [ ] shared-infrastructure
- [ ] app-service
- [ ] database
- [ ] storage
- [ ] key-vault
- [ ] networking
- [ ] dns-zones
- [ ] cloudflare
- [ ] front-door
- [ ] monitoring

## Checklist

<!-- Ensure all items are checked before requesting review -->

### Code Quality
- [ ] I have run `tofu fmt -recursive` and code is properly formatted
- [ ] I have run `tofu validate` and there are no errors
- [ ] I have run `tfsec` and addressed any findings
- [ ] I have run `checkov` and addressed any findings

### Documentation
- [ ] I have updated the README if this changes module inputs/outputs
- [ ] I have updated CHANGELOG.md with my changes
- [ ] I have added/updated comments for complex logic

### Testing
- [ ] I have tested this change in an Azure environment
- [ ] I have verified the plan output is as expected
- [ ] I have tested both apply and destroy operations

### General
- [ ] My commit messages follow conventional commits format
- [ ] I have not included sensitive information (keys, passwords, etc.)
- [ ] My changes do not introduce breaking changes (or they are documented)

## Test Configuration

<!-- Share relevant test configuration (remove sensitive values) -->

```hcl
# Example configuration used for testing
```

## Screenshots / Plan Output

<!-- If applicable, add screenshots or relevant plan output -->

## Additional Notes

<!-- Any additional information reviewers should know -->
