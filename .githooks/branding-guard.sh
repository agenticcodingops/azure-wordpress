#!/bin/sh
# Shared AI-attribution guard. Single source of truth for the patterns. Policy: AGENTS.md.
#
# It is a deny list. An AI assistant must not be a commit author, committer or co-author,
# and PR text must not carry an AI attribution line. Everyone else passes: humans,
# code-quality bots, dependency and release bots, and the fix-loop bot. Free text is never
# scanned: a subject, body, branch, tag or PR title may name any tool, model or file.

# AI assistants, matched as whole words. A name may run straight into "bot", "agent",
# "code" or "ai" (claudebot, cursoragent), but not into other letters, so a word such as
# "precursor" or "raider" does not match.
AI_NAMES='claude|anthropic|openai|chatgpt|codex|copilot|cursor|gemini|grok|antigravity|aider|jules|devin|kiro'
AI_ERE="(^|[^a-zA-Z])($AI_NAMES)(bot|agent|code|ai)?([^a-zA-Z]|\$)"
# A GPT model matches on its prefix alone, so suffixed names (GPT-4o, GPT-4.1 mini) are caught.
MODEL_ERE='(^|[^a-z])((opus|sonnet|haiku|fable)[[:space:]]*[0-9.]*[[:space:]]*(\(|<|$)|gpt-?[0-9])'
# Contributor-credit trailers. Signed-off-by (DCO) is not contributor credit and is not listed.
TRAILER_ERE='^[[:space:]]*(co-?authored-?by|claude-session|assisted-by|generated-by)[[:space:]]*:'
# A "Generated with/by ..." byline at the start of a line, after optional markup or an emoji.
BYLINE_ERE='^[^[:alnum:]]*(:robot:[^[:alnum:]]*)?generated[[:space:]]+(with|by)[[:space:]]'

# Commit messages and PR text. Rejects a contributor-credit trailer that names an AI
# assistant or model, by name or address. Lines starting with '#' are dropped (they are
# comments in the commit-msg buffer; callers pass stored text through `uncomment` first).
# Message on stdin; $1 = human-readable label. Returns 1 on a hit.
attribution_scan() {
    _label="$1"
    _tr=$(tr -d '\r' | sed '/^[[:space:]]*#/d' | grep -n -i -E "$TRAILER_ERE" 2>/dev/null \
          | grep -i -E "$AI_ERE|$MODEL_ERE" 2>/dev/null)
    if [ -n "$_tr" ]; then
        printf '  AI attribution trailer:\n%s\n' "$_tr" | sed 's/^/    /' >&2
        printf '\nBLOCKED: %s credits an AI assistant as a contributor.\n' "$_label" >&2
        return 1
    fi
    return 0
}

# PR and issue text only: the trailer rule above plus a "Generated with/by <AI>" byline.
# Never used on commit messages, so a commit body may say anything outside its trailers.
pr_text_scan() {
    _label="$1"; _text=$(tr -d '\r'); _pfail=0
    printf '%s\n' "$_text" | attribution_scan "$_label" || _pfail=1
    _by=$(printf '%s\n' "$_text" | grep -n -i -E "$BYLINE_ERE" 2>/dev/null \
          | grep -i -E "$AI_ERE|$MODEL_ERE" 2>/dev/null)
    if [ -n "$_by" ]; then
        printf '  AI attribution byline:\n%s\n' "$_by" | sed 's/^/    /' >&2
        printf '\nBLOCKED: %s carries an AI attribution byline.\n' "$_label" >&2
        _pfail=1
    fi
    return "$_pfail"
}

# Rejects an author or committer address that belongs to an AI assistant.
identity_check() {  # identity_check <email> <role> <ref>
    if printf '%s\n' "$1" | grep -q -i -E "$AI_ERE|$MODEL_ERE"; then
        printf 'BLOCKED: %s %s of %s is an AI assistant identity.\n' "$2" "$1" "${3:-commit}" >&2
        return 1
    fi
    return 0
}
