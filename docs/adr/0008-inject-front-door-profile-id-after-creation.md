# 0008: Inject the Front Door profile ID after creation

**Status:** Accepted  
**Date:** 2026-02-05  
**Code commit:** `0ca9c63afe42ba866bc0a9b748946448a699da2b`

## Context

App Service must exist before Front Door can use it as an origin, while the final origin restriction needs the newly created Front Door profile GUID.

## Decision

Create App Service with the provider-level Front Door restriction, then patch its restriction list after Front Door creation with an update resource containing `x-azure-fdid`.

## Consequences

This breaks the construction cycle and restricts the origin to one profile. Adopters must retain the post-creation patch. The web-app resource and patch manage overlapping data, so plans must be reviewed for restoration of the broader provider configuration.

## Code

- `modules/wordpress-site/main.tf:644-647` — deliberately withholds the profile ID from App Service and points to the later update.
- `modules/wordpress-site/main.tf:1012-1036` — performs the post-creation patch using the profile GUID.
