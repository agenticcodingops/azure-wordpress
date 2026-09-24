#!/bin/sh
# Shared branding/authorship scanner. Single source of truth for the patterns.

BRANDING_ERE='claude|anthropic|copilot|cursor|gemini|openai|chatgpt|codex|dependabot|claude\.ai|co-?authored[- ]with|generated with|🤖'
TRAILER_ERE='^[[:space:]]*(co-authored-by|claude-session|assisted-by|generated-by)[[:space:]]*:'
# A GPT model matches on its prefix alone, so suffixed names (GPT-4o, GPT-4.1 mini) are caught.
MODEL_ERE='(^|[^a-z])((opus|sonnet|haiku|fable)[[:space:]]*[0-9.]*[[:space:]]*(\(|<|$)|gpt-?[0-9])'

branding_scan() {
    _label="$1"; _msg=$(cat); _found=0
    _body=$(printf '%s\n' "$_msg" | sed '/^[[:space:]]*#/d')
    _hits=$(printf '%s\n' "$_body" | grep -n -i -E "$BRANDING_ERE" 2>/dev/null)
    if [ -n "$_hits" ]; then
        printf '  vendor/tool name:\n%s\n' "$_hits" | sed 's/^/    /'; _found=1
    fi
    _tr=$(printf '%s\n' "$_body" | grep -n -i -E "$TRAILER_ERE" 2>/dev/null \
          | grep -i -E 'noreply|no-reply|anthropic|claude|bot@|\[bot\]' 2>/dev/null)
    if [ -n "$_tr" ]; then
        printf '  tool-attribution trailer:\n%s\n' "$_tr" | sed 's/^/    /'; _found=1
    fi
    _md=$(printf '%s\n' "$_body" | grep -n -i -E "$TRAILER_ERE" 2>/dev/null \
          | grep -i -E "$MODEL_ERE" 2>/dev/null)
    if [ -n "$_md" ]; then
        printf '  model name used as an identity:\n%s\n' "$_md" | sed 's/^/    /'; _found=1
    fi
    if [ "$_found" -ne 0 ]; then
        printf '\nBLOCKED: %s contains prohibited vendor/tool attribution.\n' "$_label" >&2
        return 1
    fi
    return 0
}

identity_check() {
    _email="$1"; _role="$2"; _ref="$3"
    _allow="$(git rev-parse --show-toplevel 2>/dev/null)/.githooks/allowed-authors.txt"
    [ -f "$_allow" ] || return 0
    if printf '%s\n' "$_email" | grep -q -i -E 'anthropic|claude|\[bot\]|bot@'; then
        printf 'BLOCKED: %s %s of %s is a tool identity.\n' "$_role" "$_email" "${_ref:-commit}" >&2
        return 1
    fi
    if ! grep -v '^[[:space:]]*#' "$_allow" | grep -q -i -x -F "$_email"; then
        printf 'BLOCKED: %s %s of %s is not in .githooks/allowed-authors.txt\n' \
               "$_role" "$_email" "${_ref:-commit}" >&2
        return 1
    fi
    return 0
}
