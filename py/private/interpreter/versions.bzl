"""Python-build-standalone release metadata.

This file contains release dates and platform mappings for CPython interpreters
built by the python-build-standalone project
(https://github.com/astral-sh/python-build-standalone).

The actual interpreter versions and SHA256 checksums are discovered at
repository-rule time by downloading the SHA256SUMS file from each release.
This file only needs to know which release dates exist and which minor
versions they contain, so that the module extension can route version
requests to the correct release.
"""

DEFAULT_RELEASE_BASE_URL = "https://github.com/astral-sh/python-build-standalone/releases/download"

# Mapping from PBS release date to the set of Python minor versions available
# in that release. Only install_only builds are considered.
#
# This mapping is intentionally minimal: it contains no SHA256 hashes, no
# platform-specific data, and no patch version numbers. All of that is
# discovered at repository-rule time from the SHA256SUMS file.
#
# To refresh this mapping, query the GitHub releases API:
#   gh api repos/astral-sh/python-build-standalone/releases/tags/{date} \
#     --jq '[.assets[].name] | map(select(startswith("cpython") and contains("install_only")))
#           | map(split("+")[0] | split("-")[1] | split(".")[0:2] | join(".")) | unique'
#
# buildifier: disable=unsorted-dict-items
RELEASES = {
    "20260303": ["3.10", "3.11", "3.12", "3.13", "3.14", "3.15"],
    "20251209": ["3.10", "3.11", "3.12", "3.13", "3.14", "3.15"],
    "20251031": ["3.9", "3.10", "3.11", "3.12", "3.13", "3.14", "3.15"],
    "20241002": ["3.8", "3.9", "3.10", "3.11", "3.12", "3.13"],
}

# The default release dates, ordered newest-first. When a user requests a
# Python version without specifying a release, we pick the newest release
# that contains that version.
DEFAULT_RELEASE_DATES = sorted(RELEASES.keys(), reverse = True)

# Mapping from PBS platform triple to Bazel platform constraints.
# buildifier: disable=unsorted-dict-items
PLATFORMS = {
    "aarch64-apple-darwin": {
        "compatible_with": [
            "@platforms//os:macos",
            "@platforms//cpu:aarch64",
        ],
    },
    "aarch64-unknown-linux-gnu": {
        "compatible_with": [
            "@platforms//os:linux",
            "@platforms//cpu:aarch64",
        ],
    },
    "aarch64-unknown-linux-musl": {
        "compatible_with": [
            "@platforms//os:linux",
            "@platforms//cpu:aarch64",
        ],
    },
    "x86_64-apple-darwin": {
        "compatible_with": [
            "@platforms//os:macos",
            "@platforms//cpu:x86_64",
        ],
    },
    "x86_64-unknown-linux-gnu": {
        "compatible_with": [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
    },
    "x86_64-unknown-linux-musl": {
        "compatible_with": [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
    },
    "x86_64-pc-windows-msvc": {
        "compatible_with": [
            "@platforms//os:windows",
            "@platforms//cpu:x86_64",
        ],
    },
    "aarch64-pc-windows-msvc": {
        "compatible_with": [
            "@platforms//os:windows",
            "@platforms//cpu:aarch64",
        ],
    },
    "i686-pc-windows-msvc": {
        "compatible_with": [
            "@platforms//os:windows",
            "@platforms//cpu:x86_32",
        ],
    },
}

# Build configurations available from PBS. Each config specifies:
# - suffix: the build config suffix in the asset filename
# - extension: the archive file extension
# - strip_prefix: the prefix to strip when extracting
# - freethreaded: whether this is a free-threaded build
#
# buildifier: disable=unsorted-dict-items
BUILD_CONFIGS = {
    "install_only": {
        "suffix": "install_only",
        "extension": "tar.gz",
        "strip_prefix": "python",
        "freethreaded": False,
    },
    "install_only_stripped": {
        "suffix": "install_only_stripped",
        "extension": "tar.gz",
        "strip_prefix": "python",
        "freethreaded": False,
    },
    "freethreaded+pgo+lto": {
        "suffix": "freethreaded+pgo+lto-full",
        "extension": "tar.zst",
        "strip_prefix": "python/install",
        "freethreaded": True,
    },
    "freethreaded+debug": {
        "suffix": "freethreaded+debug-full",
        "extension": "tar.zst",
        "strip_prefix": "python/install",
        "freethreaded": True,
    },
}
