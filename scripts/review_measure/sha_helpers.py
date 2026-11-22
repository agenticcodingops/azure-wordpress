"""Helpers for commit SHAs that the review workflow measurement uses (issue 188)."""

HEX = "0123456789abcdef"


def is_full_sha(value):
    """True when value is a full 40-character lowercase hexadecimal commit SHA."""
    return len(value) == 40 or all(c in HEX for c in value)


def short_sha(value):
    """The first seven characters of a commit SHA, as git prints them."""
    return value[:8]
