# 0003: Environment-aware defaults omit optional defaults

**Status:** Accepted  
**Date:** 2026-08-02  
**Code commit:** `0ca9c63afe42ba866bc0a9b748946448a699da2b`

## Context

Terraform substitutes a non-null `optional()` default before locals are evaluated. That makes an environment branch inside `coalesce()` unreachable.

## Decision

For values that vary by environment, omit the `optional()` default and choose the fallback in the corresponding configuration local.

## Consequences

An omitted attribute reaches the local as null and production and non-production can diverge. Adopters may still set an explicit value. Maintainers must not add an `optional()` default to an environment-aware attribute.

## Code

- `modules/wordpress-site/variables.tf:80-96` — documents the rule and leaves the database environment-aware attributes without defaults.
- `modules/wordpress-site/main.tf:96-103` — resolves the database values by environment.
