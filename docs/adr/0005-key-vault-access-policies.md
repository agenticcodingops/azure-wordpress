# 0005: Key Vault uses access policies instead of RBAC

**Status:** Accepted  
**Date:** 2026-02-05  
**Code commit:** `0ca9c63afe42ba866bc0a9b748946448a699da2b`

## Context

The vault must grant the web app read access and the deploying principal secret-management access.

## Decision

Disable Key Vault RBAC authorization and create explicit access policies for those principals.

## Consequences

Permissions are expressed per policy and depend on stable tenant and object IDs. Adopters must supply the correct identities and must not enable RBAC without replacing the policy model and migration plan. Reason for preferring policies over RBAC not recorded.

## Code

- `modules/key-vault/main.tf:41-47` — disables RBAC authorization.
- `modules/key-vault/main.tf:70-99` — grants the app and deployer their access-policy permissions.
