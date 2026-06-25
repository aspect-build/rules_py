"""Python-build-standalone release metadata.

This file contains platform mappings and build config definitions for CPython
interpreters built by the python-build-standalone project
(https://github.com/astral-sh/python-build-standalone).

The actual interpreter versions, URLs, and SHA256 checksums are discovered at
extension evaluation time by downloading the SHA256SUMS file from each release,
then cached in the MODULE.bazel.lock via the Bazel facts API.
"""

load("//uv/private/constraints/platform:defs.bzl", "PLATFORM_LIBC_FLAG")

DEFAULT_RELEASE_BASE_URL = "https://github.com/astral-sh/python-build-standalone/releases/download"

# Default PBS release dates, ordered newest-first. These are used when the user
# does not specify any release dates via interpreters.release(). Together they
# cover Python 3.8 through 3.15.
#
# To find available releases:
#   gh api 'repos/astral-sh/python-build-standalone/releases?per_page=20' --jq '.[].tag_name'
#
# buildifier: disable=unsorted-dict-items
DEFAULT_RELEASE_DATES = [
    "20260303",  # 3.10-3.15
    "20251031",  # 3.9-3.15
    "20241002",  # 3.8-3.13
]

# `PLATFORM_LIBC_FLAG` is only applied to linux toolchains below: on
# darwin/windows there's only one libc (libsystem/msvc), so the constraint
# disambiguates nothing in target config — and on macOS/Windows hosts it
# actively breaks cfg=exec toolchain selection when a linux cross-build
# platform pins `platform_libc=glibc` and that flag inherits into the exec
# config the host's interpreter is being resolved under.

# Mapping from PBS platform triple to Bazel platform constraints.
#
# - compatible_with: constraint_values for exec_compatible_with / target_compatible_with
# - target_settings: additional config_settings the toolchain must match (optional)
# - register_exec_tools: whether the hub emits the platform's exec registration
#
# `platform_libc` is a target flag, so GNU and musl have identical exec OS/CPU
# constraints. The default target-pattern registration expands
# lexicographically, so GNU currently wins only by registration order. PBS
# Linux exec registrations support glibc hosts, so only GNU emits one:
# https://bazel.build/extending/toolchains#registering-building-toolchains
#
# buildifier: disable=unsorted-dict-items
PLATFORMS = {
    "aarch64-apple-darwin": {
        "compatible_with": [
            "@platforms//os:macos",
            "@platforms//cpu:aarch64",
        ],
        "register_exec_tools": True,
    },
    "aarch64-unknown-linux-gnu": {
        "compatible_with": [
            "@platforms//os:linux",
            "@platforms//cpu:aarch64",
        ],
        "target_settings": {
            PLATFORM_LIBC_FLAG: "glibc",
        },
        "register_exec_tools": True,
    },
    "aarch64-unknown-linux-musl": {
        "compatible_with": [
            "@platforms//os:linux",
            "@platforms//cpu:aarch64",
        ],
        "target_settings": {
            PLATFORM_LIBC_FLAG: "musl",
        },
        "register_exec_tools": False,
    },
    "x86_64-apple-darwin": {
        "compatible_with": [
            "@platforms//os:macos",
            "@platforms//cpu:x86_64",
        ],
        "register_exec_tools": True,
    },
    "x86_64-unknown-linux-gnu": {
        "compatible_with": [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
        "target_settings": {
            PLATFORM_LIBC_FLAG: "glibc",
        },
        "register_exec_tools": True,
    },
    "x86_64-unknown-linux-musl": {
        "compatible_with": [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
        "target_settings": {
            PLATFORM_LIBC_FLAG: "musl",
        },
        "register_exec_tools": False,
    },
    "x86_64-pc-windows-msvc": {
        "compatible_with": [
            "@platforms//os:windows",
            "@platforms//cpu:x86_64",
        ],
        "register_exec_tools": True,
    },
    "aarch64-pc-windows-msvc": {
        "compatible_with": [
            "@platforms//os:windows",
            "@platforms//cpu:aarch64",
        ],
        "register_exec_tools": True,
    },
    "i686-pc-windows-msvc": {
        "compatible_with": [
            "@platforms//os:windows",
            "@platforms//cpu:x86_32",
        ],
        "register_exec_tools": True,
    },
}

# Build configurations available from PBS. Each config specifies:
# - suffix: the build config suffix in the asset filename
# - extension: the archive file extension
# - strip_prefix: the prefix to strip when extracting
# - freethreaded: whether this is a free-threaded build
# - abi_flags: CPython ABI flags for the build
#
# buildifier: disable=unsorted-dict-items
BUILD_CONFIGS = {
    "install_only": {
        "abi_flags": "",
        "suffix": "install_only",
        "extension": "tar.gz",
        "strip_prefix": "python",
        "freethreaded": False,
    },
    "install_only_stripped": {
        "abi_flags": "",
        "suffix": "install_only_stripped",
        "extension": "tar.gz",
        "strip_prefix": "python",
        "freethreaded": False,
    },
    "freethreaded+pgo+lto": {
        "abi_flags": "t",
        "suffix": "freethreaded+pgo+lto-full",
        "extension": "tar.zst",
        "strip_prefix": "python/install",
        "freethreaded": True,
    },
    "freethreaded+debug": {
        "abi_flags": "td",
        "suffix": "freethreaded+debug-full",
        "extension": "tar.zst",
        "strip_prefix": "python/install",
        "freethreaded": True,
    },
}
