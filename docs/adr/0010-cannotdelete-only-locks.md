# 0010: Offer CanNotDelete-only locks

**Status:** Accepted  
**Date:** 2026-09-28  
**Code commit:** `0ca9c63afe42ba866bc0a9b748946448a699da2b`

## Context

Resource-group protection is useful, but a ReadOnly lock blocks operations needed for refresh and makes the lock difficult to manage through the same configuration.

## Decision

Accept only `CanNotDelete` locks for site and shared resource groups.

## Consequences

Deletion and replacement fail while the lock exists. Adopters must remove the lock in an earlier apply before any planned delete or replacement, then restore it afterward; they must not change the kind to ReadOnly.

## Code

- `modules/shared-infrastructure/variables.tf:84-99` — defines the AVM-shaped lock and rejects every kind except CanNotDelete.
- `modules/wordpress-site/main.tf:1187-1197` — applies the selected lock and preserves the legacy CanNotDelete behavior.
