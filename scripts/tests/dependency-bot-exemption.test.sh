#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
. "$repo_root/scripts/dependency-bot-exemption.sh"

author_name='dependabot[bot]'
author_email='49699333+dependabot[bot]@users.noreply.github.com'
committer_name='GitHub'
committer_email='noreply@github.com'

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

is_dependency_update_bot_commit \
    "$author_name" "$author_email" "$committer_name" "$committer_email" ||
    fail 'exact identity was rejected'

reject() {
    description=$1
    shift
    if is_dependency_update_bot_commit "$@"; then
        fail "$description was accepted"
    fi
}

reject 'different author name' 'dependabot' "$author_email" "$committer_name" "$committer_email"
reject 'different author email' "$author_name" '1+dependabot[bot]@users.noreply.github.com' "$committer_name" "$committer_email"
reject 'different committer name' "$author_name" "$author_email" 'github' "$committer_email"
reject 'different committer email' "$author_name" "$author_email" "$committer_name" 'merge@github.com'
reject 'differently cased address' "$author_name" '49699333+dependabot[bot]@users.noreply.GitHub.com' "$committer_name" "$committer_email"

printf 'PASS: exact identity accepted and all single-field variations rejected\n'
