# 0011: Default to a floating image tag

**Status:** Accepted  
**Date:** 2026-02-05  
**Code commit:** `0ca9c63afe42ba866bc0a9b748946448a699da2b`

## Context

The application uses the platform WordPress container. A floating supported PHP-series tag receives platform image updates, while a dated tag transfers patch tracking to the adopter.

## Decision

Default `wordpress_version` to the floating `8.3` tag and pass it to App Service as the Docker image tag.

## Consequences

Default deployments follow updates published to that tag and can change without a module release. Adopters needing reproducibility must pin a dated tag and then own image monitoring and upgrades; they must not interpret the input as a WordPress core version.

## Code

- `modules/wordpress-site/variables.tf:74-77` — documents the tag semantics and sets the floating default.
- `modules/wordpress-site/main.tf:606-606` — passes the selected value as the Docker image tag.
- `modules/app-service/main.tf:241-245` — builds the deployed container image reference.
