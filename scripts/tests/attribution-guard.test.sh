#!/bin/sh
# Tests the AI-attribution guard: .githooks/ (branding-guard.sh, guard-helpers.sh and the
# commit-msg and pre-push hooks) and the run step of .github/workflows/commit-hygiene.yml.
# The guard is a deny list: an AI assistant must not be an author, committer or co-author,
# and PR text must not carry an AI attribution line.
# Everything else passes, free text that names a tool or a file included. The hook cases run
# in throwaway repositories holding a copy of the shipped .githooks/, so the code under test
# is the code that ships. Needs git, a POSIX sh, awk and bash (for the workflow step).
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
    pass_msg $fn 'people sharing a name with an assistant' \
        'fix: x\n\nCo-authored-by: Jules Smith <jules@example.com>\nCo-authored-by: Devin Lee <devin@example.org>\n'

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
    block_msg $fn 'other assistant session trailer' \
        'fix: x\n\nCodex-Session: https://chatgpt.com/codex/tasks/task_123\n'
    block_msg $fn 'generic session-link trailer' \
        'fix: x\n\nSession-Link: https://claude.ai/code/session_123\n'
    block_msg $fn 'generic session-url trailer' 'fix: x\n\nSession-Url: https://jules.google/task/1\n'
    pass_msg $fn 'session trailer without an assistant' \
        'fix: x\n\nSession-Link: https://example.org/meetings/42\n'
    block_msg $fn 'lower-case key' 'fix: x\n\nco-authored-by: claude <x@example.com>\n'
    block_msg $fn 'key without hyphens' 'fix: x\n\nCoauthored-by: Gemini <x@example.com>\n'
    block_msg $fn 'indented trailer' 'fix: x\n\n   Co-authored-by: Copilot <x@example.com>\n'
    block_msg $fn 'CRLF message' 'fix: x\r\n\r\nCo-authored-by: Claude <noreply@anthropic.com>\r\n'
    block_msg $fn 'stacked suffixes' 'fix: x\n\nCo-authored-by: claudecodebot <x@example.com>\n'
    block_msg $fn 'stacked suffixes, assist' 'fix: x\n\nCo-authored-by: geminicodeassist <x@example.com>\n'
    block_msg $fn 'person-named assistant alone' 'fix: x\n\nCo-authored-by: Jules <jules@example.com>\n'
    block_msg $fn 'person-named assistant app' \
        'fix: x\n\nCo-authored-by: google-labs-jules[bot] <161369871+google-labs-jules[bot]@users.noreply.github.com>\n'
    block_msg $fn 'person-named assistant with suffix' \
        'fix: x\n\nCo-authored-by: Devin AI <158243242+devin-ai-integration[bot]@users.noreply.github.com>\n'
    block_msg $fn 'person-named assistant vendor domain' 'fix: x\n\nCo-authored-by: Dev <x@kiro.dev>\n'
    block_msg $fn 'one bad trailer among good ones' \
        'fix: x\n\nCo-authored-by: Dev <dev@example.org>\nCo-authored-by: Codex <codex@openai.com>\n'
    # A model word in a trailer follows the name and address rule: it needs a version.
    block_msg $fn 'hyphenated model version as co-author' \
        'fix: x\n\nCo-authored-by: Sonnet-4.5 <x@example.com>\n'
    block_msg $fn 'model address under a human name' \
        'fix: x\n\nCo-authored-by: Dev <opus-4.5@example.com>\n'
    pass_msg $fn 'person called Haiku as co-author' \
        'fix: x\n\nCo-authored-by: Haiku <haiku@example.com>\n'
    pass_msg $fn 'person called Fable as co-author' \
        'fix: x\n\nCo-authored-by: Fable <fable@example.com>\n'
done

# A byline is K2 wording for PR and issue text; a commit body outside its trailers is free text.
pass_msg attribution_scan 'byline in a commit body' 'fix: x\n\nGenerated with Claude Code\n'

# --- PR text: trailers plus a "Generated with/by <AI>" byline -------------------------------
pass_msg pr_text_scan 'PR body naming tools' \
    '## Summary\n\nNarrows the guard; CLAUDE.md, the codex lane and .gemini/styleguide.md change.\n'
pass_msg pr_text_scan 'byline naming a non-AI generator' 'Generated with terraform-docs\n'
pass_msg pr_text_scan 'release PR footer' \
    'This PR was generated with [Release Please](https://github.com/googleapis/release-please).\n'
pass_msg pr_text_scan 'AI named after the generator, past a semicolon' \
    'Generated by terraform-docs; reviewed in codex\n'
pass_msg pr_text_scan 'AI named in the next sentence' 'Generated by terraform-docs. Reviewed by codex.\n'
pass_msg pr_text_scan 'person-named generator' 'Generated by Jules Smith\n'
pass_msg pr_text_scan 'mention of generation mid-sentence' \
    'The table below was generated with Claude from the plan output.\n'
block_msg pr_text_scan 'AI byline with emoji and link' \
    '## Summary\n\nx\n\n\0360\0237\0244\0226 Generated with [Claude Code](https://claude.com/claude-code)\n'
block_msg pr_text_scan 'AI byline, plain' 'Generated by Copilot\n'
block_msg pr_text_scan 'AI byline in emphasis' '_Generated with ChatGPT_\n'
block_msg pr_text_scan 'AI byline after a shortcode' ':robot: Generated with Codex\n'
block_msg pr_text_scan 'AI byline in an HTML tag' '<sub>Generated with Claude</sub>\n'
block_msg pr_text_scan 'AI byline with a colon' 'Generated with: Claude Code\n'
block_msg pr_text_scan 'AI byline with using' 'Generated using Claude Code\n'
block_msg pr_text_scan 'model byline' 'Generated by Opus 4.5\n'
block_msg pr_text_scan 'person-named assistant byline' 'Generated by Jules\n'
# Only the generator is checked: prose after it may name any tool or file.
pass_msg pr_text_scan 'file named after the generator' 'Generated by terraform-docs for CLAUDE.md\n'
pass_msg pr_text_scan 'list of files named after the generator' \
    'Generated by terraform-docs for README.md and CLAUDE.md\n'
pass_msg pr_text_scan 'linked files named after the generator' \
    'Generated by [terraform-docs](https://terraform-docs.io) for README.md, AGENTS.md and CLAUDE.md\n'
pass_msg pr_text_scan 'AI named in a parenthesis after the generator' \
    'Generated by terraform-docs (reviewed with Codex)\n'
pass_msg pr_text_scan 'AI named after a comma and a verb' 'Generated by terraform-docs, reviewed by Codex\n'
pass_msg pr_text_scan 'linked generator whose URL path names a file' \
    'Generated with [terraform-docs](https://github.com/terraform-docs/terraform-docs/blob/main/CLAUDE.md)\n'
pass_msg pr_text_scan 'person-named generator in bold' 'Generated with **Jules Smith**\n'
pass_msg pr_text_scan 'linked person-named generator' 'Generated by [Devin Patel](https://example.org/devin)\n'
pass_msg pr_text_scan 'person called Haiku as generator' 'Generated by Haiku\n'
# Markup around a person-named assistant must not hide it.
block_msg pr_text_scan 'linked person-named assistant' 'Generated with [Jules](https://jules.google)\n'
block_msg pr_text_scan 'person-named assistant in bold' 'Generated with **Kiro**\n'
block_msg pr_text_scan 'person-named assistant in emphasis' 'Generated by _Devin_\n'
# shellcheck disable=SC2016 # the backticks are literal Markdown code ticks
block_msg pr_text_scan 'person-named assistant in code ticks' 'Generated by `Jules`\n'
block_msg pr_text_scan 'link to an assistant vendor host' 'Generated with [My Tool](https://devin.ai/x)\n'
block_msg pr_text_scan 'AI in a generator list' 'Generated by terraform-docs and Claude\n'
block_msg pr_text_scan 'AI generator before a file name' 'Generated with Claude Code for CLAUDE.md\n'
block_msg pr_text_scan 'hyphenated model byline' 'Generated by Sonnet-4.5\n'
# A link at the start of a generator list must not hide the generators after it.
block_msg pr_text_scan 'linked generator, then a plain AI generator' \
    'Generated by [terraform-docs](https://terraform-docs.io) and Claude\n'
block_msg pr_text_scan 'linked generator, then a linked AI generator' \
    'Generated by [terraform-docs](https://terraform-docs.io) and [Claude](https://claude.ai)\n'
block_msg pr_text_scan 'linked generator, then a link to an assistant host' \
    'Generated by [terraform-docs](https://terraform-docs.io), [My Tool](https://devin.ai/x)\n'
block_msg pr_text_scan 'plain generator, then a linked AI generator' \
    'Generated by terraform-docs and [Codex](https://example.org/x)\n'
pass_msg pr_text_scan 'two linked non-AI generators' \
    'Generated by [terraform-docs](https://terraform-docs.io) and [Release Please](https://github.com/googleapis/release-please)\n'
pass_msg pr_text_scan 'AI link after the generator, past prose' \
    'Generated by [terraform-docs](https://terraform-docs.io) for [CLAUDE.md](https://claude.ai/x)\n'
pass_msg pr_text_scan 'AI link in the next sentence' \
    'Generated by [terraform-docs](https://terraform-docs.io). See [Claude](https://claude.ai).\n'
block_msg pr_text_scan 'session-link line in a PR body' \
    'Summary\n\nSession-Link: https://claude.ai/code/session_123\n'
block_msg pr_text_scan 'AI co-author line in a PR body' \
    'Summary\n\nCo-authored-by: Claude <noreply@anthropic.com>\n'

# --- Identities: AI assistants are denied, everyone else passes ----------------------------
for addr in dev@example.org autofix@auto-code-scanning.invalid \
    '49699333+dependabot[bot]@users.noreply.github.com' \
    '136622811+coderabbitai[bot]@users.noreply.github.com' support@semgrep.com \
    noreply@github.com '340677216+agenticcodingops-orchestrator@users.noreply.github.com' \
    'release-bot@example.org' jules@example.com devin@example.org haiku@example.com     fable@example.com opus.dei@example.org; do
    pass_id identity_check "$addr"
done
for addr in noreply@anthropic.com codex@openai.com cursoragent@cursor.com \
    '209825114+claude[bot]@users.noreply.github.com' \
    '198982749+Copilot@users.noreply.github.com' 'devin-ai-integration[bot]@users.noreply.github.com' \
    gpt-5@example.com x@kiro.dev opus-4.5@example.com sonnet4@example.com     'haiku-4-5@example.com'; do
    block_id identity_check "$addr"
done
for name in 'Syed Hassan Abbas' 'auto-code-scanning-autofix[bot]' 'dependabot[bot]' \
    'coderabbitai[bot]' 'github-actions[bot]' GitHub 'Orchestrator Agent' 'Jo Raider' \
    'Precursor Labs' Devinder 'Devin Patel' 'Jules Smith' Haiku Fable 'Opus Dei'; do
    pass_id name_check "$name"
done
for name in Claude 'claude[bot]' Codex 'Cursor Agent' Copilot 'Gemini' 'Grok' 'aider' \
    'GPT-5' 'Claude Opus 4.5' 'Opus 4.5' 'Sonnet-4.5' ClaudeBot claudecodebot Jules Kiro 'Devin AI' \
    'google-labs-jules[bot]'; do
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
# The configured identity itself is checked against the deny list, by address and by name.
if git -C "$r" -c user.email=noreply@anthropic.com commit -q --allow-empty -m 'fix: x' 2>/dev/null; then
    fail 'commit-msg: a configured AI address was accepted'
fi
if git -C "$r" -c user.name=Claude commit -q --allow-empty -m 'fix: x' 2>/dev/null; then
    fail 'commit-msg: a configured AI name was accepted'
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

# commit-msg drops '#' lines as buffer comments, but `-m` keeps them in the stored message,
# so pre-push (which runs `uncomment` first) must catch a commented AI trailer.
c -m 'fix: hash' -m '# Co-authored-by: Claude <noreply@anthropic.com>' ||
    fail "commit-msg: a '#' trailer line was rejected"
if git -C "$r" push -q origin HEAD:refs/heads/feature/h 2>/dev/null; then
    fail "pre-push: a '# Co-authored-by' AI trailer was accepted"
fi
git -C "$r" reset -q --hard HEAD~1
# The same trailer committed with the hooks off, as --no-verify would: pre-push still rejects it.
git -C "$r" -c core.hooksPath=/dev/null commit -q --allow-empty -m 'fix: hash'     -m '# Co-authored-by: Claude <noreply@anthropic.com>' ||
    fail "could not create the '#' trailer commit with the hooks off"
if git -C "$r" push -q origin HEAD:refs/heads/feature/h2 2>/dev/null; then
    fail "pre-push: a '# Co-authored-by' AI trailer committed with the hooks off was accepted"
fi
git -C "$r" reset -q --hard HEAD~1

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

# --- The Commit Hygiene workflow's run step ------------------------------------------------
# CI is the one layer --no-verify cannot skip, so run its actual script, extracted from the
# workflow file, against a scratch repository the way the runner would (bash -eo pipefail).
command -v bash >/dev/null 2>&1 || fail 'bash is needed to run the workflow step'
wf="$repo_root/.github/workflows/commit-hygiene.yml"
step="$work/hygiene-step.sh"
awk '{ sub(/\r$/, "") }
     /- name: Scan commits and PR body/ { f = 1 }
     f && /^ *run: \|[[:space:]]*$/ { match($0, /^ */); ind = RLENGTH; g = 1; next }
     g { if ($0 ~ /^[[:space:]]*$/) { print ""; next }
         match($0, /^ */); if (RLENGTH <= ind) exit
         print substr($0, ind + 3) }' "$wf" >"$step"
grep -q 'pr_text_scan' "$step" || fail 'could not extract the workflow run step'
# The runner has openssl; a bare container may not. The token only needs to be unique.
mkdir -p "$work/bin"
if ! command -v openssl >/dev/null 2>&1; then
    printf '#!/bin/sh\necho 0123456789abcdef0123456789abcdef\n' >"$work/bin/openssl"
    chmod +x "$work/bin/openssl"
fi

ciremote="$work/ci-remote.git"
ci="$work/ci"
git init -q --bare "$ciremote"
git init -q "$ci"
git -C "$ci" config user.name 'Dev Person'
git -C "$ci" config user.email dev@example.org
git -C "$ci" config core.hooksPath /dev/null
git -C "$ci" remote add origin "$ciremote"
mkdir -p "$ci/.githooks"
cp "$repo_root/.githooks/branding-guard.sh" "$repo_root/.githooks/guard-helpers.sh" "$ci/.githooks/"
git -C "$ci" commit -q --allow-empty -m 'chore: base'
git -C "$ci" branch -M main
git -C "$ci" push -q origin main
git -C "$ci" fetch -q origin
base=$(git -C "$ci" rev-parse HEAD)

ci_commit() {  # ci_commit <pr number> <git commit args...>: prints the new commit's SHA
    _n="$1"; shift
    git -C "$ci" checkout -q --detach "$base"
    git -C "$ci" commit -q --allow-empty "$@" || fail 'could not create a CI test commit'
    git -C "$ci" push -q origin "HEAD:refs/pull/$_n/head" || fail 'could not push a CI test ref'
    git -C "$ci" rev-parse HEAD
}

# hygiene <event> <before or base> <after or head> <ref name> <pr number> <pr body>
hygiene() {
    (cd "$ci" && PATH="$work/bin:$PATH" EVENT_NAME="$1" REF_TYPE=branch BEFORE="$2" AFTER="$3" \
        BASE_SHA="$2" HEAD_SHA="$3" REF_NAME="$4" PR_NUMBER="$5" PR_BODY="$6" \
        DEFAULT_BRANCH=main bash -eo pipefail "$step" >/dev/null 2>&1)
}

clean=$(ci_commit 1 -m 'docs: update CLAUDE.md for the codex lane' \
    -m 'Co-authored-by: coderabbitai[bot] <136622811+coderabbitai[bot]@users.noreply.github.com>')
ai_coauthor=$(ci_commit 2 -m 'fix: x' -m 'Co-authored-by: Claude <noreply@anthropic.com>')
ai_author=$(ci_commit 3 --author='Claude <noreply@anthropic.com>' -m 'fix: x')
ai_address=$(ci_commit 5 --author='Dev <dev@openai.com>' -m 'fix: x')
ai_name=$(ci_commit 6 --author='Claude <dev@example.org>' -m 'fix: x')
hashed=$(ci_commit 4 -m 'fix: x' -m '# Co-authored-by: Codex <codex@openai.com>')
tool_body='## Summary

Changes CLAUDE.md, .gemini/styleguide.md and the dependabot config; reviewed in codex.'

hygiene pull_request_target "$base" "$clean" claude/x 1 "$tool_body" ||
    fail 'workflow: clean PR with a tool-named branch and body was rejected'
if hygiene pull_request_target "$base" "$clean" claude/x 1 "$tool_body

Generated with [Claude Code](https://claude.com/claude-code)"; then
    fail 'workflow: AI byline in the PR body was accepted'
fi
if hygiene pull_request_target "$base" "$ai_coauthor" feature/y 2 'Summary'; then
    fail 'workflow: PR with an AI co-author commit was accepted'
fi
if hygiene pull_request_target "$base" "$ai_author" feature/z 3 'Summary'; then
    fail 'workflow: PR with an AI author commit was accepted'
fi
if hygiene pull_request_target "$base" "$hashed" feature/h 4 'Summary'; then
    fail "workflow: a '# Co-authored-by' AI trailer was accepted"
fi
hygiene push "$base" "$clean" codex/branch '' '' ||
    fail 'workflow: push of a clean commit to a tool-named branch was rejected'
if hygiene push "$base" "$ai_author" feature/z '' ''; then
    fail 'workflow: push of an AI author commit was accepted'
fi
if hygiene push "$base" "$ai_address" feature/a '' ''; then
    fail 'workflow: push of a commit with an AI author address was accepted'
fi
if hygiene push "$base" "$ai_name" feature/n '' ''; then
    fail 'workflow: push of a commit with an AI author name was accepted'
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
