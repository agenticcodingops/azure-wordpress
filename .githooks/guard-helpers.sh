#!/bin/sh
# Helpers shared by the hooks and the Commit Hygiene workflow. Source branding-guard.sh
# first: name_check reuses its patterns, which stay the single source of truth.

# branding_scan drops '#' lines because they are comments in the commit-msg buffer. A
# stored message or PR text has no comments left — `git commit -m` keeps '#' lines
# verbatim, and a '## Heading' is content — so strip the markers and scan those lines.
# Strip the whole leading run of spaces and markers: '# #text' must not survive as ' #text'.
uncomment() { sed 's/^[[:space:]#]*//'; }

is_zero() { [ -z "$(printf '%s' "$1" | tr -d 0)" ]; }

# identity_check covers addresses only. A name is identity too, so reject vendor, bot and
# model names even on an allow-listed address.
name_check() {  # name_check <name> <role> <ref>
    if printf '%s\n' "$1" | grep -q -i -E "$BRANDING_ERE|\[bot\]|$MODEL_ERE"; then
        printf 'BLOCKED: %s name "%s" of %s is a vendor, bot or model name.\n' "$2" "$1" "$3" >&2
        return 1
    fi
    return 0
}
