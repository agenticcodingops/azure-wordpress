#!/bin/sh
# Tests the AI-attribution guard in .githooks/ (branding-guard.sh, guard-helpers.sh and the
# commit-msg and pre-push hooks). The guard is a deny list: an AI assistant must not be an
# author, committer or co-author, and PR text must not carry an AI attribution line.
# Everything else passes, free text that names a tool or a file included. The hook cases run
# in throwaway repositories holding a copy of the shipped .githooks/, so the code under test
# is the code that ships. Needs git and a POSIX sh.
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# run <function> <text>: exit status of a guard function reading the text on stdin.
run() {
    (. "$repo_root/.githooks/branding-guard.sh" && . "$repo_root/.githooks/guard-helpers.sh" &&
        printf '%b' "$2" | "$1" test 2>/dev/null)
}
pass_msg() { run "$1" "$3" || fail "$1: $2 was rejected"; }
block_msg() { if run "$1" "$3"; then fail "$1: $2 was accepted"; fi; }

# ident <function> <value>: exit status of identity_check or name_check.
ident() {
    (. "$repo_root/.githooks/branding-guard.sh" && . "$repo_root/.githooks/guard-helpers.sh" &&
        "$1" "$2" author test 2>/dev/null)
}
pass_id() { ident "$1" "$2" || fail "$1: $2 was rejected"; }
block_id() { if ident "$1" "$2"; then fail "$1: $2 was accepted"; fi; }

fixloop='auto-code-scanning-autofix[bot] <autofix@auto-code-scanning.invalid>'

# --- Commit messages: only contributor-credit trailers are read --------------------------
for fn in attribution_scan pr_text_scan; do
    pass_msg $fn 'message without trailers' 'fix: x\n\nbody\n'
    pass_msg $fn 'subject naming the guidance file' 'docs: update CLAUDE.md for the codex lane\n'
    pass_msg $fn 'body naming tools and models' \
        'chore: x\n\nReviewed by Gemini and Copilot; tested with Opus 4.5 and GPT-5.\nBump via the dependabot config.\n'
    pass_msg $fn 'robot emoji in free text' 'fix: x\n\n\0360\0237\0244\0226 release notes\n'
    pass_msg $fn 'human co-author' 'fix: x\n\nCo-authored-by: Dev <dev@example.org>\n'
    pass_msg $fn 'human noreply co-author' \
        'fix: x\n\nCo-authored-by: Someone <123+someone@users.noreply.github.com>\n'
    pass_msg $fn 'code-quality bot co-author' \
        'fix: x\n\nCo-authored-by: coderabbitai[bot] <136622811+coderabbitai[bot]@users.noreply.github.com>\n'
    pass_msg $fn 'static-analysis co-author' 'fix: x\n\nCo-authored-by: Semgrep <support@semgrep.com>\n'
    pass_msg $fn 'fix-loop bot co-author' "fix: x\n\nCo-authored-by: $fixloop\n"
    pass_msg $fn 'dependency bot co-author' \
        'chore(deps): x\n\nCo-authored-by: dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>\n'
    pass_msg $fn 'DCO sign-off naming a tool' 'fix: x\n\nSigned-off-by: Claude <noreply@anthropic.com>\n'
    pass_msg $fn 'substring of a tool name' \
        'fix: x\n\nCo-authored-by: Jo Raider <raider@precursor.example>\n'
    pass_msg $fn 'commented-out trailer' 'fix: x\n\n# Co-authored-by: Codex <codex@openai.com>\n'

    block_msg $fn 'general assistant co-author' 'fix: x\n\nCo-authored-by: Claude <noreply@anthropic.com>\n'
    block_msg $fn 'coding agent co-author' 'fix: x\n\nCo-authored-by: Codex <codex@openai.com>\n'
    block_msg $fn 'editor agent co-author' \
        'fix: x\n\nCo-authored-by: Cursor Agent <cursoragent@cursor.com>\n'
    block_msg $fn 'terminal agent co-author' 'fix: x\n\nCo-authored-by: aider <aider@aider.chat>\n'
    block_msg $fn 'AI app bot co-author' \
        'fix: x\n\nCo-authored-by: claude[bot] <209825114+claude[bot]@users.noreply.github.com>\n'
    block_msg $fn 'AI address under a human name' 'fix: x\n\nCo-authored-by: Dev <dev@openai.com>\n'
    block_msg $fn 'model name as co-author' 'fix: x\n\nCo-authored-by: Opus 4.5 <x@example.com>\n'
    block_msg $fn 'GPT model in an assisted-by trailer' 'fix: x\n\nAssisted-by: GPT-4o\n'
    block_msg $fn 'session-link trailer' 'fix: x\n\nClaude-Session: https://example.com/s/1\n'
    block_msg $fn 'lower-case key' 'fix: x\n\nco-authored-by: claude <x@example.com>\n'
    block_msg $fn 'key without hyphens' 'fix: x\n\nCoauthored-by: Gemini <x@example.com>\n'
    block_msg $fn 'indented trailer' 'fix: x\n\n   Co-authored-by: Copilot <x@example.com>\n'
    block_msg $fn 'CRLF message' 'fix: x\r\n\r\nCo-authored-by: Claude <noreply@anthropic.com>\r\n'
    block_msg $fn 'one bad trailer among good ones' \
        'fix: x\n\nCo-authored-by: Dev <dev@example.org>\nCo-authored-by: Codex <codex@openai.com>\n'
done

# A byline is K2 wording for PR and issue text; a commit body outside its trailers is free text.
pass_msg attribution_scan 'byline in a commit body' 'fix: x\n\nGenerated with Claude Code\n'

# --- PR text: trailers plus a "Generated with/by <AI>" byline -------------------------------
pass_msg pr_text_scan 'PR body naming tools' \
    '## Summary\n\nNarrows the guard; CLAUDE.md, the codex lane and .gemini/styleguide.md change.\n'
pass_msg pr_text_scan 'byline naming a non-AI generator' 'Generated with terraform-docs\n'
pass_msg pr_text_scan 'release PR footer' \
    'This PR was generated with [Release Please](https://github.com/googleapis/release-please).\n'
pass_msg pr_text_scan 'mention of generation mid-sentence' \
    'The table below was generated with Claude from the plan output.\n'
block_msg pr_text_scan 'AI byline with emoji and link' \
    '## Summary\n\nx\n\n\0360\0237\0244\0226 Generated with [Claude Code](https://claude.com/claude-code)\n'
block_msg pr_text_scan 'AI byline, plain' 'Generated by Copilot\n'
block_msg pr_text_scan 'AI byline in emphasis' '_Generated with ChatGPT_\n'
block_msg pr_text_scan 'AI byline after a shortcode' ':robot: Generated with Codex\n'
block_msg pr_text_scan 'AI co-author line in a PR body' \
    'Summary\n\nCo-authored-by: Claude <noreply@anthropic.com>\n'

# --- Identities: AI assistants are denied, everyone else passes ----------------------------
for addr in dev@example.org autofix@auto-code-scanning.invalid \
    '49699333+dependabot[bot]@users.noreply.github.com' \
    '136622811+coderabbitai[bot]@users.noreply.github.com' support@semgrep.com \
    noreply@github.com '340677216+agenticcodingops-orchestrator@users.noreply.github.com' \
    'release-bot@example.org'; do
    pass_id identity_check "$addr"
done
for addr in noreply@anthropic.com codex@openai.com cursoragent@cursor.com \
    '209825114+claude[bot]@users.noreply.github.com' \
    '198982749+Copilot@users.noreply.github.com' 'devin-ai-integration[bot]@users.noreply.github.com'; do
    block_id identity_check "$addr"
done
for name in 'Syed Hassan Abbas' 'auto-code-scanning-autofix[bot]' 'dependabot[bot]' \
    'coderabbitai[bot]' 'github-actions[bot]' GitHub 'Orchestrator Agent' 'Jo Raider' \
    'Precursor Labs' Devinder; do
    pass_id name_check "$name"
done
for name in Claude 'claude[bot]' Codex 'Cursor Agent' Copilot 'Gemini' 'Grok' 'aider' \
    'GPT-5' 'Claude Opus 4.5' 'Opus 4.5' ClaudeBot; do
    block_id name_check "$name"
done

# --- The hooks end to end -----------------------------------------------------------------
LEFTHOOK=0
export LEFTHOOK
remote="$work/remote.git"
git init -q --bare "$remote"
r="$work/clone"
git init -q "$r"
mkdir -p "$r/.githooks"
cp "$repo_root/.githooks/branding-guard.sh" "$repo_root/.githooks/guard-helpers.sh" \
    "$repo_root/.githooks/commit-msg" "$repo_root/.githooks/pre-push" "$r/.githooks/"
chmod +x "$r/.githooks/commit-msg" "$r/.githooks/pre-push"
git -C "$r" config core.hooksPath .githooks
git -C "$r" config user.name 'Dev Person'
git -C "$r" config user.email dev@example.org
git -C "$r" remote add origin "$remote"
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL 2>/dev/null || true

c() { git -C "$r" commit -q --allow-empty "$@" 2>/dev/null; }

c -m 'docs: update CLAUDE.md and the codex lane' ||
    fail 'commit-msg: subject naming the guidance file was rejected'
c -m 'fix: x' -m 'Co-authored-by: coderabbitai[bot] <136622811+coderabbitai[bot]@users.noreply.github.com>' ||
    fail 'commit-msg: code-quality bot co-author was rejected'
if c -m 'fix: x' -m 'Co-authored-by: Codex <codex@openai.com>'; then
    fail 'commit-msg: AI co-author was accepted'
fi
if c --author='Claude <noreply@anthropic.com>' -m 'fix: x'; then
    fail 'commit-msg: AI author was accepted'
fi
if c --author='Other Human <other@example.org>' -m 'fix: x'; then
    fail 'commit-msg: an identity other than the configured one was accepted'
fi

# The fix-loop bot commits in CI, where no hook runs; pre-push must still let it through.
git -C "$r" -c "user.name=auto-code-scanning-autofix[bot]" \
    -c user.email=autofix@auto-code-scanning.invalid \
    -c core.hooksPath=/dev/null commit -q --allow-empty -m 'fix: apply autofix' ||
    fail 'could not create the fix-loop commit'
git -C "$r" push -q origin HEAD:refs/heads/claude/x 2>/dev/null ||
    fail 'pre-push: branch claude/x with a fix-loop bot commit was rejected'
git -C "$r" tag -a v0.0.1 -m 'Release prepared with Codex and Gemini' ||
    fail 'could not create the tag'
git -C "$r" push -q origin v0.0.1 2>/dev/null || fail 'pre-push: tag message naming tools was rejected'

git -C "$r" -c core.hooksPath=/dev/null commit -q --allow-empty -m 'fix: y' \
    -m 'Co-authored-by: Claude <noreply@anthropic.com>' || fail 'could not create the AI co-author commit'
if git -C "$r" push -q origin HEAD:refs/heads/feature/y 2>/dev/null; then
    fail 'pre-push: AI co-author commit was accepted'
fi
git -C "$r" reset -q --hard HEAD~1
git -C "$r" -c user.name=Claude -c user.email=noreply@anthropic.com -c core.hooksPath=/dev/null \
    commit -q --allow-empty -m 'fix: z' || fail 'could not create the AI author commit'
if git -C "$r" push -q origin HEAD:refs/heads/feature/z 2>/dev/null; then
    fail 'pre-push: AI author commit was accepted'
fi

# The allow-list files are gone; nothing may still read them.
for f in allowed-authors.txt allowed-coauthors.txt; do
    [ ! -e "$repo_root/.githooks/$f" ] || fail ".githooks/$f still exists"
done
if grep -n -E 'allowed-(co)?authors|BRANDING_ERE|branding_scan|coauthor_check|dependency_update_bot' \
    "$repo_root/.githooks/"* "$repo_root/.github/workflows/commit-hygiene.yml" >/dev/null; then
    fail 'a hook or the workflow still uses the removed allow-list or free-text scan'
fi

printf 'PASS: AI attribution denied; tool names in free text, other bots and humans accepted\n'
