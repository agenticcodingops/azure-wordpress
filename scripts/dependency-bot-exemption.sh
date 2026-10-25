#!/bin/sh
# Used only by the Commit Hygiene workflow's push scan of the default branch (issue #130).
# Match the identity GitHub records when it merges a dependency-update pull request.
# Keep these comparisons exact: this is a narrow exception, not an identity allow-list.
is_dependency_update_bot_commit() {  # <author-name> <author-email> <committer-name> <committer-email>
    [ "$1" = 'dependabot[bot]' ] &&
        [ "$2" = '49699333+dependabot[bot]@users.noreply.github.com' ] &&
        [ "$3" = 'GitHub' ] &&
        [ "$4" = 'noreply@github.com' ]
}
