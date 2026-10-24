# 0001: Two-layer model and early Application Insights

**Status:** Accepted  
**Date:** 2026-02-05  
**Code commit:** `0ca9c63afe42ba866bc0a9b748946448a699da2b`

## Context

The composition has a foundation layer and an application layer. Application Insights must exist between them because its connection string is one of the secrets written before the web app is created.

## Decision

Keep the two explicit layers. Create the workspace and Application Insights after the foundation and before the application resources.

## Consequences

The ordering breaks a dependency cycle and makes the connection string available to Key Vault. Adopters must not move Application Insights behind App Service or remove the layer dependencies without redesigning secret creation.

## Code

- `modules/wordpress-site/main.tf:326-368` — declares Layer 1 and explains the early monitoring dependency.
- `modules/wordpress-site/main.tf:395-399` — declares Layer 2 and its ordering.
- `modules/wordpress-site/main.tf:511-516` — puts the Application Insights connection string in the owned secrets map.
