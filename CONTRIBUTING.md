# Contributing

Thank you for contributing. Check existing issues before opening a new one, keep each
change focused, and never include credentials or other sensitive values in an issue or
pull request.

## Set up a local checkout

1. Fork the repository and clone your fork.
2. Add the canonical repository as the `upstream` remote.
3. Install the required tools:
   - Terraform 1.17.1 (the version used by CI)
   - terraform-docs 0.20.0
   - Checkov 3.3.22
   - Trivy
   - Python 3.11 or newer, with PyYAML 6.0.3 and jsonschema 4.25.1
   - Lefthook and the scanners configured in `lefthook.yml`
   - Bash 4.4 or newer for shell hooks; on macOS, install a supported Bash and put it first on PATH
4. Install the repository hooks once per clone:

   ```bash
   sh .githooks/install.sh
   ```

   Do not install another hook manager over these hooks. Read the commit-metadata
   policy in [AGENTS.md](AGENTS.md) before creating branches, commits, or pull requests.
   The hooks enforce that policy and dispatch the configured local scanners.

Create a short-lived branch with a descriptive prefix such as `feature/`, `fix/`,
`docs/`, `refactor/`, or `test/`.

## Format and validate Terraform

Confirm that the selected binary is the same version as CI, then run the CI commands
from the repository root:

```bash
terraform version
terraform fmt -recursive -check -diff

for module in modules/*/; do
  (cd "$module" && terraform init -backend=false && terraform validate) || exit 1
done
```

CI starts without module lock files. If local initialization created `.terraform/`
directories or module lock files, remove them before checking generated documentation.

## Generate module documentation

After changing a module input, output, or resource, regenerate that module's README
with terraform-docs 0.20.0. This is the inject operation enforced by CI:

```bash
terraform-docs markdown table --indent 2 --output-mode inject --output-file README.md \
  --output-template '<!-- BEGIN_TF_DOCS -->
{{ .Content }}
<!-- END_TF_DOCS -->' modules/<module>
```

Review the resulting diff and ensure a second run is idempotent.

## Run the compliance scan

CI parity uses Checkov 3.3.22. The v3.1.2 push hooks require a trusted executable
named `checkov` on PATH and scan files changed by each pushed ref. New refs compare with the destination
remote default; fallback selection counts only that destination's remote-tracking refs. Keep those refs current before pushing. For the suffixed parity command:

```bash
pipx install --suffix=@3322 checkov==3.3.22
```

Run it with the same render setting and skip list that the validation workflow uses:

```bash
RENDER_EDGES_DUPLICATE_ITER_COUNT=50 checkov@3322 -d . --framework terraform --quiet \
  --skip-check "$(sed -n 's/^ *skip_check: *\([^[:space:]]*\).*/\1/p' .github/workflows/validate.yml)"
```

The workflow is the canonical skip-list source. The tracked push policy at
`.scanning/configs/.checkov.yaml` mirrors it, and the scan settings job rejects drift.
Update the mirror whenever changing the workflow list. CI also reads that policy. Only passive Checkov keys are accepted. Pre-commit security scanners read staged index blobs; pre-push scanners read pushed object tips and their changed paths, so staged-but-unpushed content is excluded from push scans. SQLFluff uses the working tree. Python and every scanner must resolve outside both the scanned and consumer checkouts, even with `SCAN_ALLOW_TOOL_ERRORS=1`. Trusted executable configuration must resolve outside the checkout. Semgrep ruleset overrides may use registry references, staged files inside the checkout, or external paths.

Install hook validation dependencies with Python 3.11 or newer:

```bash
python -m pip install PyYAML==6.0.3 jsonschema==4.25.1
```

For tflint, provision a reviewed `.hcl` config and plugin cache outside the checkout,
then set absolute `SCAN_TFLINT_CONFIG` and `SCAN_TFLINT_PLUGIN_DIR` paths. Start with
the pinned platform release's `configs/azure/.tflint.hcl`, without any `plugin_dir`
setting. Missing prerequisites now block local scans. The push off-switch is read
from the pushed commit, while staged configuration validation always runs.
There is no suppression registry or baseline here to migrate to schema 2.0. The local hook also runs Trivy at its configured severity:

```bash
trivy config . --severity CRITICAL --skip-dirs .terraform
```

## Verify changes without cloud credentials

Provider-backed plans require credentials, but expression behavior and plan structure
can be checked offline.

Use `terraform console` against the real module to inspect variables and locals. Keep
plugin data outside the checkout and supply required inputs through a temporary variable
file that is not committed:

```bash
export TF_DATA_DIR="$(mktemp -d)"
terraform -chdir=modules/wordpress-site init -backend=false
terraform -chdir=modules/wordpress-site console -var-file=<temporary-inputs-file>
```

Wrap expressions in `jsonencode()` when checking null values, because a bare null prints
as a blank line.

For changes that need a plan-level assertion, add a temporary `.tftest.hcl` fixture.
Set `command = plan`, because a `terraform test` run applies by default. Every provider
used by the tested configuration needs its own `mock_provider` block: this can include
`azurerm`, `azapi`, `random`, `time`, `null`, and `cloudflare` when
`cdn_provider = "cloudflare"`. A minimal plan-only fixture for the direct CDN path is:

```hcl
mock_provider "azurerm" {}
mock_provider "azapi" {}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "null" {}

run "direct_cdn_plan" {
  command = plan

  variables {
    project_name  = "example"
    site_name     = "example"
    environment   = "nonprod"
    location      = "eastus"
    tenant_id     = "00000000-0000-0000-0000-000000000000"
    custom_domain = "example.com"
    cdn_provider  = "direct"
  }
}
```

Then run:

```bash
terraform -chdir=modules/wordpress-site test -verbose
```

Mock-provider tests verify planned configuration without contacting the provider. Check
the command's exit code and assert specific resources and attributes so two identical
failures cannot be mistaken for a successful before-and-after comparison. Do not commit
temporary fixtures or generated initialization files unless they are part of the change.

## Commits and pull requests

Use Conventional Commits, for example:

```text
feat(storage): add an optional setting
fix(database): correct input validation
docs(readme): clarify an example
```

Open the pull request directly against `main`. **Do not stack pull requests.** A pull
request based on another feature branch does not run the complete validation workflow,
and squash-merging its base can leave later changes disconnected from `main`. Wait for
the current pull request to land, update from `main`, and then open the next one.

Before requesting review:

1. Run the format, validation, compliance, and documentation commands above.
2. Complete every applicable part of the pull request template, including documentation
   impact and offline verification.
3. Confirm that all required checks pass.
4. Request an independent review of diagrams and technical claims against the code.

## Releases

Releases are automated. A conventional commit merged to `main` causes the release
automation to open or update a release pull request. Merging that release pull request
updates the changelog and manifest, creates the version tag, and publishes the release.
Do not edit the changelog or create tags by hand.

- `fix:` produces a patch release.
- `feat:` produces a minor release.
- `feat!:` or a `BREAKING CHANGE:` footer produces a major release.
- `docs:` and `chore:` do not produce a release.

```mermaid
flowchart LR
    A[Release-triggering commit: fix, feat, or breaking change] --> B[Release pull request]
    B -->|Maintainer merges| C[Version tag]
    C --> D[GitHub Release]
    E[docs or chore commit] --> F[No release pull request]
```

## Review guidance

Reviewers check readability, Terraform conventions, validation and test evidence,
documentation completeness, safe handling of sensitive values, and whether the change
introduces a documented compatibility impact. Prefer descriptive names, `for_each` when
resource identity matters, locals for derived values, and validation blocks for input
constraints.

## Local linter configuration

The root `.tflint.hcl` is byte-identical to the scanning platform's
`configs/azure/.tflint.hcl` at v3.1.2. Its embedded example uses the platform's
standard layout; for this repository's root mirror, run:

```bash
tflint --init --config="$(pwd)/.tflint.hcl"
tflint --recursive --config="$(pwd)/.tflint.hcl"
```

Push hooks continue to require the reviewed config and plugin cache outside the
checkout, selected by `SCAN_TFLINT_CONFIG` and `SCAN_TFLINT_PLUGIN_DIR`. Provision
that external config from the same release. The runtime minimums in the local
scan config remain compatibility floors, not installation pins.
