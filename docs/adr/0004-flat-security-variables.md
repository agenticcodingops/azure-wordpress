# 0004: Security settings use flat top-level variables

**Status:** Accepted  
**Date:** 2026-09-28  
**Code commit:** `0ca9c63afe42ba866bc0a9b748946448a699da2b`

## Context

Static analysers cannot reliably see security controls nested in `optional()` object attributes.

## Decision

Expose security-relevant switches and diagnostic settings as flat top-level variables rather than object attributes.

## Consequences

Scanners can evaluate the controls directly, at the cost of a wider top-level interface. Adopters must treat these inputs as independent security controls; maintainers must not move them into optional objects solely for grouping.

## Code

- `modules/wordpress-site/variables.tf:706-713` — states the scanner limitation and declares a flat diagnostic-settings input.
- `modules/wordpress-site/variables.tf:107-110` — identifies the staged security switches as flat top-level values.
