# 0012: Prefer Azure Verified Modules

**Status:** Accepted  
**Date:** 2026-09-26  
**Code commit:** `0ca9c63afe42ba866bc0a9b748946448a699da2b`

## Context

Common input shapes reduce migration cost, but available verified resource modules may be incompatible with this repository’s Terraform or provider constraints.

## Decision

Use an available compatible Azure Verified Module first for new resources. When compatibility prevents that, use the provider resource and shape its interface like the verified module.

## Consequences

Maintainers must check compatibility before adding a resource and pin a selected module exactly. Existing bespoke modules are migrated when touched, not wholesale. The current lock and diagnostic interfaces preserve compatible shapes while their resources remain direct provider resources.

## Code

- `AGENTS.md:80-86` — establishes the verified-module-first rule, compatibility checks, and migration boundary.
- `modules/shared-infrastructure/variables.tf:84-91` — exposes the verified-module lock shape.
- `modules/wordpress-site/variables.tf:706-711` — models diagnostic settings on the verified-module interface while noting provider limitations.
