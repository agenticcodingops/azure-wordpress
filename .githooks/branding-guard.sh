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
# with a bot/agent/ai suffix or a [bot] tag, at a vendor domain (in an address, a URL or a bare
# host), as a whole name field, or as the whole name in a trailer. "Jules Smith" and "Devin
# Patel" are people and pass.
PERSON_NAMES='jules|devin|kiro'
PERSON_ERE="(^|[^a-zA-Z])($PERSON_NAMES)([-_[:space:]]?(bot|agent|ai)([^a-zA-Z]|\$)|\[bot\])|(^|[@./])(jules\.google|devin\.ai|cognition\.ai|kiro\.dev)([^a-zA-Z]|\$)|^[[:space:]]*($PERSON_NAMES)[[:space:]]*\$|:[[:space:]]*($PERSON_NAMES)[[:space:]]*(<|\$)"
# Models. A model word counts only with a version number, the same in a name, an address, a
# trailer or a byline: Opus 4.5, Sonnet-4.5, opus-4.5@ and sonnet4@ are caught, while a person
# called Haiku or Fable passes. "Claude Opus" is still caught by AI_ERE. A GPT model matches on
# its prefix, so suffixed names (GPT-4o, GPT-4.1 mini) are caught.
MODEL_ERE='(^|[^a-z])((opus|sonnet|haiku|fable)[[:space:]-]*[0-9]|gpt-?[0-9])'
# Every assistant pattern. Trailers, bylines, names and addresses all use this one list.
DENY_ERE="$AI_ERE|$PERSON_ERE|$MODEL_ERE"
# Contributor-credit trailers, session-link trailers included: any key containing "session"
# (Claude-Session, Codex-Session, Session-Link, Session-Url). Signed-off-by (DCO) is not
# contributor credit and is not listed.
TRAILER_ERE='^[[:space:]]*(co-?authored-?by|assisted-by|generated-by|[[:alnum:]_-]*session[[:alnum:]_-]*)[[:space:]]*:'
# A "Generated with/by/using ..." byline at the start of a line, after optional markup, HTML
# tags (<sub>, <p>) or an emoji. Matched on lower-cased text. pr_text_scan checks only the
# generator it names (see byline_generators), never the prose after it.
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

# Prints what a lower-cased byline line credits as its generator, one candidate per line, so
# each is matched as a whole identity. Markup goes first: HTML tags, emphasis and code ticks.
# Each Markdown link becomes one token that cutting and splitting keep whole, and gives its
# label and its host. The text is then cut at '(', ';', ' - ' or a sentence end, split into a
# list at ',', '&', 'and' or 'or', and each item is cut at the first word that starts other
# prose (for, from, in, with, by, ...). So "terraform-docs for CLAUDE.md" yields only
# "terraform-docs", and "[terraform-docs](...) and [Claude](...)" yields both labels and hosts.
byline_generators() {
    sed -E "s/$BYLINE_ERE//; s/<[^>]*>/ /g; s/[*\`~]+//g; s/(^|[[:space:]])_+/\1/g; s/_+([[:space:]]|\$)/\1/g" |
        awk '
        function trim(t) { sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t); return t }
        function host(u,  k) {
            sub(/^[a-z][a-z0-9+.-]*:\/\//, "", u); k = index(u, "/")
            if (k > 0) u = substr(u, 1, k - 1)
            gsub(/[ \t(;,&]/, "", u); return u
        }
        BEGIN { LB = "\035"; HS = "\036"; EN = "\034"; SP = "\037" }
        {
            s = trim($0); out = ""
            while (match(s, /\[[^]]*\]\([^)]*\)/)) {
                lk = substr(s, RSTART, RLENGTH); j = index(lk, "](")
                lbl = substr(lk, 2, j - 2); gsub(/[ \t(;,&]/, SP, lbl)
                out = out substr(s, 1, RSTART - 1) LB lbl HS host(substr(lk, j + 2, length(lk) - j - 2)) EN
                s = substr(s, RSTART + RLENGTH)
            }
            s = out s
            if (match(s, /[(;]|[.!?]([ \t]|$)| - /)) s = substr(s, 1, RSTART - 1)
            gsub(/,|&|[ \t]and[ \t]|[ \t]or[ \t]/, "\n", s)
            n = split(s, part, "\n")
            for (i = 1; i <= n; i++) {
                p = " " trim(part[i]) " "
                if (match(p, /[ \t](for|from|in|on|at|via|to|of|after|under|with|by|using|as|that|which|while|then|but|so|because|when)[ \t]/))
                    p = substr(p, 1, RSTART - 1)
                while ((a = index(p, LB)) > 0) {
                    rest = substr(p, a + 1); b = index(rest, HS); c = index(rest, EN)
                    lbl = substr(rest, 1, b - 1); gsub(SP, " ", lbl); lbl = trim(lbl)
                    if (lbl != "") print lbl
                    h = substr(rest, b + 1, c - b - 1); if (h != "") print h
                    p = substr(p, 1, a - 1) " " substr(rest, c + 1)
                }
                p = trim(p)
                if (p != "") print p
            }
        }'
}

# PR and issue text only: the trailer rule above plus a "Generated with/by/using <AI>" byline.
# Never used on commit messages, so a commit body may say anything outside its trailers.
pr_text_scan() {
    _label="$1"; _text=$(tr -d '\r'); _pfail=0
    printf '%s\n' "$_text" | attribution_scan "$_label" || _pfail=1
    _by=$(printf '%s\n' "$_text" | tr '[:upper:]' '[:lower:]' | grep -n -E "$BYLINE_ERE" 2>/dev/null \
          | while IFS= read -r _l; do
                if printf '%s\n' "${_l#*:}" | byline_generators | grep -q -E "$DENY_ERE"; then
                    printf '%s\n' "$_l"
                fi
            done)
    if [ -n "$_by" ]; then
        printf '  AI attribution byline:\n%s\n' "$_by" | sed 's/^/    /' >&2
        printf '\nBLOCKED: %s carries an AI attribution byline.\n' "$_label" >&2
        _pfail=1
    fi
    return "$_pfail"
}

# Rejects an author or committer address that belongs to an AI assistant or model:
# opus-4.5@example.com is denied, haiku@example.com passes.
identity_check() {  # identity_check <email> <role> <ref>
    if printf '%s\n' "$1" | grep -q -i -E "$DENY_ERE"; then
        printf 'BLOCKED: %s %s of %s is an AI assistant identity.\n' "$2" "$1" "${3:-commit}" >&2
        return 1
    fi
    return 0
}
