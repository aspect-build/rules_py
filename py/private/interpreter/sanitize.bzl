"""Shared helper for building Bazel repo names from version/platform strings."""

def sanitize(s):
    """Replace characters that are invalid in Bazel repo names with underscores."""
    return s.replace(".", "_").replace("-", "_").replace("+", "_")
