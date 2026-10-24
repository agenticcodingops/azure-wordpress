# 0007: Use one cdn_provider switch

**Status:** Accepted  
**Date:** 2026-02-05  
**Code commit:** `0ca9c63afe42ba866bc0a9b748946448a699da2b`

## Context

Edge selection affects module creation, DNS behavior, and origin IP restrictions. Independent booleans could select conflicting paths.

## Decision

Use one validated `cdn_provider` value with exactly three composition choices: `cloudflare`, `azure_front_door`, or `direct`.

## Consequences

Only one edge path is selected. Adopters must plan provider changes as cutovers and must not add a second independent selector that can conflict with this value.

## Code

- `modules/wordpress-site/variables.tf:531-540` — defines and validates the single switch.
- `modules/wordpress-site/main.tf:182-197` — derives mutually exclusive Front Door and Cloudflare enablement.
