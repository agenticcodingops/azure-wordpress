#!/bin/sh
# Shared AI-attribution guard. Single source of truth for the patterns. Policy: AGENTS.md.
#
# It is a deny list. An AI assistant must not be a commit author, committer or co-author,
# and PR text must not carry an AI attribution line. Everyone else passes: humans,
# code-quality bots, dependency and release bots, and the fix-loop bot. Free text is never
# scanned: a subject, body, branch, tag or PR title may name any tool, model or file.

# AI assistants, matched as whole words. A name may run straight into "bot", "agent",
# "code", "ai" or "assist", once or several times (claudebot, cursoragent, claudecodebot,
# geminicodeassist), but not into other letters, so a word such as "precursor" or "raider"
# does not match.
AI_NAMES='claude|anthropic|openai|chatgpt|codex|copilot|cursor|gemini|grok|antigravity|aider'
AI_ERE="(^|[^a-zA-Z])($AI_NAMES)(bot|agent|code|ai|assist)*([^a-zA-Z]|\$)"
# Assistants that share a name with people (Jules, Devin, Kiro). They match only as the agent:
# with a bot/agent/ai suffix or a [bot] tag, at a vendor domain, as a whole name field, or as
# the whole name in a trailer. "Jules Smith" and "Devin Patel" are people and pass.
PERSON_NAMES='jules|devin|kiro'
PERSON_ERE="(^|[^a-zA-Z])($PERSON_NAMES)([-_[:space:]]?(bot|agent|ai)([^a-zA-Z]|\$)|\[bot\])|[@.](jules\.google|devin\.ai|cognition\.ai|kiro\.dev)([^a-zA-Z]|\$)|^[[:space:]]*($PERSON_NAMES)[[:space:]]*\$|:[[:space:]]*($PERSON_NAMES)[[:space:]]*(<|\$)"
# A GPT model matches on its prefix alone, so suffixed names (GPT-4o, GPT-4.1 mini) are caught.
MODEL_ERE='(^|[^a-z])((opus|sonnet|haiku|fable)[[:space:]]*[0-9.]*[[:space:]]*(\(|<|$)|gpt-?[0-9])'
# For a name or an address: a model word counts only with a version number, so a person
# called Haiku or Fable passes, while opus-4.5@ or sonnet4@ is caught. "Claude Opus" is still
# caught by AI_ERE. Read here by identity_check and by name_check in guard-helpers.sh.
MODEL_NAME_ERE='(^|[^a-z])((opus|sonnet|haiku|fable)[[:space:]-]*[0-9]|gpt-?[0-9])'
# Every assistant pattern. Trailers use this; identity_check adds MODEL_NAME_ERE, and
# name_check swaps it in for MODEL_ERE.
DENY_ERE="$AI_ERE|$PERSON_ERE|$MODEL_ERE"
# Contributor-credit trailers. Signed-off-by (DCO) is not contributor credit and is not listed.
TRAILER_ERE='^[[:space:]]*(co-?authored-?by|claude-session|assisted-by|generated-by)[[:space:]]*:'
# A "Generated with/by/using ..." byline at the start of a line, after optional markup, HTML
# tags (<sub>, <p>) or an emoji. Matched on lower-cased text. pr_text_scan checks only the
# generator named right after it, up to ';' or the end of a sentence.
BYLINE_ERE='^([^[:alnum:]<]|<[^>]*>)*(:robot:([^[:alnum:]<]|<[^>]*>)*)?generated[[:space:]]+(with|by|using)[[:space:]]*:?[[:space:]]*'

# Commit messages and PR text. Rejects a contributor-credit trailer that names an AI
# assistant or model, by name or address. Lines starting with '#' are dropped (they are
# comments in the commit-msg buffer; callers pass stored text through `uncomment` first).
# Message on stdin; $1 = human-readable label. Returns 1 on a hit.
attribution_scan() {
    _label="$1"
    _tr=$(tr -d '\r' | sed '/^[[:space:]]*#/d' | grep -n -i -E "$TRAILER_ERE" 2>/dev/null \
          | grep -i -E "$DENY_ERE" 2>/dev/null)
    if [ -n "$_tr" ]; then
        printf '  AI attribution trailer:\n%s\n' "$_tr" | sed 's/^/    /' >&2
        printf '\nBLOCKED: %s credits an AI assistant as a contributor.\n' "$_label" >&2
        return 1
    fi
    return 0
}

# PR and issue text only: the trailer rule above plus a "Generated with/by/using <AI>" byline.
# Never used on commit messages, so a commit body may say anything outside its trailers.
pr_text_scan() {
    _label="$1"; _text=$(tr -d '\r'); _pfail=0
    printf '%s\n' "$_text" | attribution_scan "$_label" || _pfail=1
    # Keep only the generator: drop the byline lead-in, then cut at ';' or a sentence end.
    _by=$(printf '%s\n' "$_text" | tr '[:upper:]' '[:lower:]' | grep -n -E "$BYLINE_ERE" 2>/dev/null \
          | while IFS= read -r _l; do
                _gen=$(printf '%s\n' "${_l#*:}" | sed -E "s/$BYLINE_ERE//; s/(;|\.([[:space:]]|\$)).*//")
                if printf '%s\n' "$_gen" | grep -q -E "$DENY_ERE"; then printf '%s\n' "$_l"; fi
            done)
    if [ -n "$_by" ]; then
        printf '  AI attribution byline:\n%s\n' "$_by" | sed 's/^/    /' >&2
        printf '\nBLOCKED: %s carries an AI attribution byline.\n' "$_label" >&2
        _pfail=1
    fi
    return "$_pfail"
}

# Rejects an author or committer address that belongs to an AI assistant or model. MODEL_ERE
# needs a '(', '<' or line end after the version, which an address never has, so the
# versioned-model pattern is added: opus-4.5@example.com is denied, haiku@example.com passes.
identity_check() {  # identity_check <email> <role> <ref>
    if printf '%s\n' "$1" | grep -q -i -E "$DENY_ERE|$MODEL_NAME_ERE"; then
        printf 'BLOCKED: %s %s of %s is an AI assistant identity.\n' "$2" "$1" "${3:-commit}" >&2
        return 1
    fi
    return 0
}
