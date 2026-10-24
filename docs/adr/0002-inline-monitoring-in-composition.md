# 0002: Monitoring is inline in the composition module

**Status:** Accepted  
**Date:** 2026-02-05  
**Code commit:** `0ca9c63afe42ba866bc0a9b748946448a699da2b`

## Context

The repository has a standalone monitoring module, but the site composition needs telemetry before it can create Key Vault and App Service.

## Decision

Create the workspace and Application Insights directly in the composition module rather than instantiate the standalone monitoring module.

## Consequences

The composition can control the early dependency edge. Changes to the standalone monitoring module do not automatically change composed sites; maintainers must update the inline resources separately when equivalent behavior is intended. Reason not recorded beyond the dependency ordering visible in code.

## Code

- `modules/wordpress-site/main.tf:364-393` — creates both core monitoring resources inline.
- `modules/wordpress-site/main.tf:520-572` — consumes Application Insights before App Service and includes it in the Key Vault dependency.
