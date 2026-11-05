# Resolve tools without bootstrapping path validation through an unchecked Python.
_tool_identity() {
    local path="$1" mode="${2:-canonical}" component parent target hop
    if command -v cygpath >/dev/null 2>&1; then
        # Expand Windows short names before converting to a comparable POSIX path.
        path="$(cygpath -alw -- "$path")" || return 1
        path="$(cygpath -au -- "$path")" || return 1
    fi
    if [[ "$mode" == lexical ]]; then
        local parts=() normalized=()
        IFS=/ read -r -a parts <<< "$path"
        for component in "${parts[@]}"; do
            case "$component" in
                ''|.) ;;
                ..) [[ ${#normalized[@]} -eq 0 ]] || unset 'normalized[${#normalized[@]}-1]' ;;
                *) normalized+=("$component") ;;
            esac
        done
        path="$(IFS=/; printf '/%s' "${normalized[*]}")"
    else
        for ((hop=0; hop<40; hop++)); do
            if [[ -d "$path" ]]; then
                path="$(cd -P -- "$path" && pwd -P)" || return 1
                break
            fi
            parent="$(cd -P -- "$(dirname -- "$path")" && pwd -P)" || return 1
            path="$parent/$(basename -- "$path")"
            [[ -L "$path" ]] || break
            target="$(readlink -- "$path")" || return 1
            if [[ "$target" == /* ]]; then path="$target"; else path="$parent/$target"; fi
        done
        [[ "$hop" -lt 40 ]] || { hook_error 'Too many links in tool path'; return 1; }
    fi
    case "${OSTYPE:-}" in msys*|cygwin*) path="${path,,}" ;; esac
    printf '%s\n' "$path"
}

verify_tool_path() {
    local path="$1" root boundary identity parent invoked canonical lexical
    [[ "$path" == /* || "$path" == [a-zA-Z]:[\\/]* ]] || {
        hook_error 'Tool must resolve to an absolute executable path'; return 1;
    }
    lexical="$(_tool_identity "$path" lexical)" || return 1
    canonical="$(_tool_identity "$path")" || return 1
    # Resolve the parent the system will actually use. POSIX follows a link before a later
    # `..`, so derive it from the original path there; Windows applies `..` lexically, so
    # the converted lexical path is both correct and the only form dirname can split.
    local parent_source="$path"
    command -v cygpath >/dev/null 2>&1 && parent_source="$lexical"
    parent="$(_tool_identity "$(dirname -- "$parent_source")")" || return 1
    invoked="$parent/$(basename -- "$lexical")"
    local roots=()
    if [[ "${SCAN_PUSH_SNAPSHOT:-0}" == 1 || "${SCAN_INDEX_SNAPSHOT:-0}" == 1 ]]; then
        roots+=("$PWD")
        [[ -z "${SCAN_CONSUMER_ROOT:-}" ]] || roots+=("$SCAN_CONSUMER_ROOT")
    else
        require_scan_git
        root="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" || return 1
        roots+=("$root")
    fi
    for root in "${roots[@]}"; do
        for boundary in "$(_tool_identity "$root")" "$(_tool_identity "$root" lexical)"; do
            [[ -n "$boundary" ]] || return 1
            boundary="${boundary%/}"
            for identity in "$lexical" "$canonical" "$invoked"; do
                case "$identity/" in "$boundary/"*)
                    hook_error 'Tool must resolve outside the scanned and consumer checkouts'; return 1 ;;
                esac
            done
        done
    done
    # Keep the invoked path: resolving a venv's final symlink loses its packages.
    printf '%s\n' "$path"
}

resolve_verified_tool() {
    local path
    # type -P ignores functions and aliases, unlike command -v.
    path="$(type -P -- "$1")" || return 1
    verify_tool_path "$path"
}
