## Description

<!-- Describe the change and why it is needed. -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update
- [ ] Refactoring with no functional change

## Related issues

<!-- Link related issues, for example: Fixes #123. -->

## Modules affected

<!-- List the affected modules, or write "none". -->

## Verification

- [ ] `terraform fmt -recursive -check -diff`
- [ ] Each affected module passes `terraform init -backend=false` and `terraform validate`
- [ ] The pinned Checkov scan passes with the workflow's render setting and skip list
- [ ] Generated module documentation is current
- [ ] Applicable offline console or mock-provider tests pass
- [ ] No sensitive information is included

<!-- Describe any checks that were not applicable or could not be run. -->

## Documentation

<!-- List every document changed, or write "no docs impact" and explain why. -->

## Worker report
- Status: done | blocked | needs-human
- What changed:
- Commands run, with exit codes (or "not run here; CI verifies"):
- CI run URL:
- Open questions:
- Risk: low | high, and why. High: a change to module behaviour or defaults that alters plans for existing users, a workflow, release or security setting, anything irreversible, or low confidence.
