#!/bin/sh
# Tests coauthor_check in .githooks/branding-guard.sh. Each case runs in a throwaway
# repository holding a copy of the shipped guard, so the code under test is the code
# that ships. Needs git and a POSIX sh.
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

approved='dev@example.org'
review_bot='136622811+coderabbitai[bot]@users.noreply.github.com'

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# make_repo <dir> <with-allowlist: yes|no> <with-coauthor-list: yes|no>
make_repo() {
    mkdir -p "$1/.githooks"
    git -C "$1" init -q
    cp "$repo_root/.githooks/branding-guard.sh" "$1/.githooks/"
    if [ "$2" = yes ]; then
        printf '# approved\n%s\n' 'DEV@EXAMPLE.ORG' >"$1/.githooks/allowed-authors.txt"
    fi
    if [ "$3" = yes ]; then
        printf '# tools\n%s\n' "$review_bot" >"$1/.githooks/allowed-coauthors.txt"
    fi
}

# check <dir> <message>: exit status of coauthor_check on the message
check() {
    (cd "$1" && . ./.githooks/branding-guard.sh &&
        printf '%b' "$2" | coauthor_check test 2>/dev/null)
}

pass_case() {
    check "$1" "$3" || fail "$2 was rejected"
}

block_case() {
    if check "$1" "$3"; then fail "$2 was accepted"; fi
}

r="$work/main"
make_repo "$r" yes no

pass_case "$r" 'message without co-author' 'fix: x\n\nbody\n'
pass_case "$r" 'approved co-author, other case' "fix: x\n\nCo-authored-by: Dev <$approved>\n"
pass_case "$r" 'approved co-author, CRLF' "fix: x\r\n\r\nCo-authored-by: Dev <$approved>\r\n"
pass_case "$r" 'commented-out line' 'fix: x\n\n# Co-authored-by: Codex <codex@openai.com>\n'

block_case "$r" 'general assistant' 'fix: x\n\nCo-authored-by: Claude <noreply@anthropic.com>\n'
block_case "$r" 'coding agent' 'fix: x\n\nCo-authored-by: Codex <codex@openai.com>\n'
block_case "$r" 'editor agent' 'fix: x\n\nCo-authored-by: Cursor Agent <cursoragent@cursor.com>\n'
block_case "$r" 'terminal agent' 'fix: x\n\nCo-authored-by: aider <aider@aider.chat>\n'
block_case "$r" 'unlisted human' 'fix: x\n\nCo-authored-by: Teammate <teammate@example.org>\n'
block_case "$r" 'line without address' 'fix: x\n\nCo-authored-by: Someone\n'
block_case "$r" 'lower-case key' 'fix: x\n\nco-authored-by: X <x@example.com>\n'
block_case "$r" 'key without hyphen' 'fix: x\n\nCoauthored-by: X <x@example.com>\n'
block_case "$r" 'indented line' 'fix: x\n\n   Co-authored-by: X <x@example.com>\n'
block_case "$r" 'one bad line among good ones' \
    "fix: x\n\nCo-authored-by: Dev <$approved>\nCo-authored-by: Codex <codex@openai.com>\n"
block_case "$r" 'prefixed address' "fix: x\n\nCo-authored-by: Dev <x$approved>\n"
block_case "$r" 'suffixed address' "fix: x\n\nCo-authored-by: Dev <$approved.evil>\n"
block_case "$r" 'address read as a grep option' "fix: x\n\nCo-authored-by: Dev <-e$approved>\n"
block_case "$r" 'review bot without the co-author list' "fix: x\n\nCo-authored-by: R <$review_bot>\n"

r="$work/listed"
make_repo "$r" yes yes
pass_case "$r" 'tool from the co-author list' "fix: x\n\nCo-authored-by: R <$review_bot>\n"
block_case "$r" 'tool not on the co-author list' 'fix: x\n\nCo-authored-by: Codex <codex@openai.com>\n'

r="$work/no-list"
make_repo "$r" no no
block_case "$r" 'co-author with no allow-list (fails closed)' "fix: x\n\nCo-authored-by: Dev <$approved>\n"
pass_case "$r" 'no co-author with no allow-list' 'fix: x\n'

# The shipped co-author list must hold only what AGENTS.md names.
shipped="$repo_root/.githooks/allowed-coauthors.txt"
[ -f "$shipped" ] || fail 'the co-author list is missing'
if grep -v '^[[:space:]]*#' "$shipped" | sed '/^[[:space:]]*$/d' |
    grep -v -i -E 'coderabbit|semgrep|sonar' | grep -q .; then
    fail 'the co-author list holds an address outside CodeRabbit, Semgrep and SonarCloud'
fi

printf 'PASS: approved co-authors accepted, every other co-author rejected\n'
