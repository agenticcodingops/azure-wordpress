# Upgrade the module

## When to use

You pin the module with `?ref=v<VERSION>` and want to move to a newer release. The same steps apply to a patch, a
minor and a major release; a major release needs the extra reading in step 1.

## Prerequisites

- The release you run now, and the one you want. Releases are cut by release-please from conventional commits, so
  `fix:` is a patch, `feat:` a minor and `feat!:` or a `BREAKING CHANGE:` footer a major
  ([Version guarantees](../../README.md#version-guarantees)).
- Terraform at the version your CI uses. This repository validates with Terraform 1.9.8, and the deployment guide
  pins the same version for consumers.
- Providers pinned exactly in the root and a committed `.terraform.lock.hcl`
  ([deployment guide step 3](../deployment-guide.md#step-3-pin-providers-exactly-and-commit-the-lock-file)).
- The pipeline from the [deployment guide](../deployment-guide.md): nonprod applies first, production waits for a
  reviewer.
- No `depends_on` on the module call, and the lock state of the resource groups known (a `CanNotDelete` lock turns
  any replacement into a failed apply).

## Steps

1. **Read what changed between your release and the target.** List the releases, then read the upgrade page for
   every transition in between ([upgrade guide](../upgrading/README.md)) and the changelog entry of each release:

   ```bash
   gh release list -R agenticcodingops/azure-wordpress --limit 10
   gh release view v<TARGET> -R agenticcodingops/azure-wordpress
   ```

   Look for `BREAKING CHANGES`, new provider bounds, and any input whose default changed. A release can also
   change a default without a breaking marker; the upgrade pages say so where it happened (for example the container
   image default in [4.0 to 4.1](../upgrading/v4.0-to-v4.1.md)).

2. **Change the pin in a branch.** Update `?ref=` in every `module` source that points at this repository, and
   change `required_providers` only if the release's notes say a provider range moved. Do not skip releases that
   carry an upgrade page; read each.

3. **Update the providers and the lock file.**

   ```bash
   terraform init -upgrade -input=false -backend-config=backend.hcl
   terraform providers lock -platform=linux_amd64 -platform=windows_amd64 -platform=darwin_arm64
   ```

   Commit the lock file change. Add every platform your CI and operators run on to `-platform`; a lock file that
   holds hashes for only one platform fails `terraform init` on the others.

4. **Plan nonprod and read it.** Compare it with the "Expected plan" section of the upgrade page.

   ```bash
   terraform plan -input=false -lock-timeout=10m -no-color > plan.txt
   grep -n -E "must be replaced|forces replacement|will be destroyed" plan.txt
   ```

   Delete `plan.txt` when done: a plan can print values you do not want in a log or an artifact. Stop if the plan
   replaces or destroys the MySQL server, the storage account, the web app or the Key Vault, or if it updates or
   replaces `azurerm_key_vault_access_policy.terraform`
   ([Troubleshooting](troubleshooting.md#a-plan-wants-to-replace-the-terraform-access-policy)). A version bump alone
   is expected to plan no resource change when the release's opt-ins stay off (see
   [4.1.1 to 4.3.0](../upgrading/v4.1.1-to-v4.3.0.md)); the upgrade page for each release says otherwise where it is not so.

5. **Merge and apply nonprod, then check the site** ([Verify](#verify)).

6. **Repeat for production** in a second pull request. Read the production plan before you approve the apply (the
   pipeline in the deployment guide plans and applies in one job unless you split it, see
   [step 5](../deployment-guide.md#step-5-write-the-pipeline)).

7. **Turn on new opt-ins separately.** A pin bump and an opt-in are different changes: do each opt-in in its own pull
   request ([deployment guide step 13](../deployment-guide.md#step-13-turn-on-the-v430-opt-ins-one-at-a-time)).

## Verify

- A re-plan as the environment's CI identity reports no changes. With `azure_front_door`, the plan after an apply is
  not empty (see [deployment guide Verify item 1](../deployment-guide.md#verify)).
- `azurerm_key_vault_access_policy.terraform` was not updated or replaced in any plan.
- The site answers and the health check is green (`curl -sS -o /dev/null -w '%{http_code}\n' https://<custom-domain>/wp-includes/images/blank.gif` prints `200`).
- `terraform version` and the lock file match what CI runs.

## Rollback

Decide per environment, because nonprod applies before production
([deployment guide, Rollback](../deployment-guide.md#rollback)):

- **No apply has run there with the new providers:** set the previous `?ref=`, the previous provider pins and the
  previous lock file, then plan.
- **An apply has run there:** set only the previous `?ref=`. Keep the newer pins and lock file if the previous
  version's provider constraints allow them. An apply upgrades the state of any resource whose schema version the
  new provider has raised, and an older provider that cannot read that version stops the plan with
  `Resource instance managed by newer provider version`. If no resource's schema changed, a provider rollback may still
  work; check the plan to find out.
- **The previous version's constraints exclude the newer providers** (any move back from v4.x to v3.x): roll forward
  with a fix instead.
- **Read the revert's plan** before it applies. A revert restores configuration, not data, and it can replace
  something the original change only updated.

Some changes cannot be undone by reverting a pin: Key Vault purge protection, the soft-delete retention period,
`geo_redundant_backup`, a MySQL major-version upgrade, removing a site, and a provider upgrade that raised a schema
version. The deployment guide lists them.

## Sources

[Upgrade guide](../upgrading/README.md), [deployment guide](../deployment-guide.md), `CHANGELOG.md`,
`.github/workflows/validate.yml` (`TERRAFORM_VERSION`).
