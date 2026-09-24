#!/bin/sh
# Activates the versioned hooks in this clone. core.hooksPath is local config and is never
# cloned, so run this once in every fresh clone:   sh .githooks/install.sh
#
# The hooks here also run the lefthook scanners, so do not run `lefthook install`
# afterwards: it refuses while core.hooksPath is set, and its --reset-hooks-path option
# would unset it and silently disable this guard.
set -e

root=$(git rev-parse --show-toplevel)
git -C "$root" config core.hooksPath .githooks
chmod +x "$root/.githooks/commit-msg" "$root/.githooks/pre-commit" "$root/.githooks/pre-push" \
    "$root/.githooks/branding-guard.sh" "$root/.githooks/guard-helpers.sh" \
    "$root/.githooks/install.sh" 2>/dev/null || true
echo "core.hooksPath = .githooks (commit-msg, pre-commit, pre-push)"

email=$(git -C "$root" config user.email || true)
if ! grep -v '^[[:space:]]*#' "$root/.githooks/allowed-authors.txt" | grep -q -i -x -F "$email"; then
    echo "WARNING: user.email '$email' is not in .githooks/allowed-authors.txt;" \
         "every commit will be rejected until it is added." >&2
fi
