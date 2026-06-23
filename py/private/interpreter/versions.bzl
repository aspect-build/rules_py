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
#
# Linux exec registrations use GNU PBS artifacts only. Bazel sees the GNU and
# musl artifacts as the same OS/CPU execution platform because the libc flag is
# target configuration, not an execution-platform constraint. Registering both
# would make selection ambiguous; GNU exec tools instead require a glibc host.

# Mapping from PBS platform triple to Bazel platform constraints.
# Optimized free-threaded archives use different suffixes on macOS/GNU Linux,
# musl Linux, and Windows. These exact mappings are visible in PBS manifests:
# https://github.com/astral-sh/python-build-standalone/releases/download/20260303/SHA256SUMS
# https://github.com/astral-sh/python-build-standalone/releases/download/20260414/SHA256SUMS
#
# - compatible_with: constraint_values for exec_compatible_with / target_compatible_with
# - asset_suffixes: exact PBS filename suffix for each logical build config
# - register_exec_tools: whether the artifact may run on an execution platform
# - target_settings: additional config_settings the toolchain must match (optional)
#
# buildifier: disable=unsorted-dict-items
PLATFORMS = {
    "aarch64-apple-darwin": {
        "asset_suffixes": {
            "install_only": "install_only",
            "freethreaded": "freethreaded+pgo+lto-full",
        },
        "compatible_with": [
            "@platforms//os:macos",
            "@platforms//cpu:aarch64",
        ],
        "register_exec_tools": True,
    },
    "aarch64-unknown-linux-gnu": {
        "asset_suffixes": {
            "install_only": "install_only",
            "freethreaded": "freethreaded+pgo+lto-full",
        },
        "compatible_with": [
            "@platforms//os:linux",
            "@platforms//cpu:aarch64",
        ],
        "register_exec_tools": True,
        "target_settings": {
            PLATFORM_LIBC_FLAG: "glibc",
        },
    },
    "aarch64-unknown-linux-musl": {
        "asset_suffixes": {
            "install_only": "install_only",
            "freethreaded": "freethreaded+lto-full",
        },
        "compatible_with": [
            "@platforms//os:linux",
            "@platforms//cpu:aarch64",
        ],
        "register_exec_tools": False,
        "target_settings": {
            PLATFORM_LIBC_FLAG: "musl",
        },
    },
    "x86_64-apple-darwin": {
        "asset_suffixes": {
            "install_only": "install_only",
            "freethreaded": "freethreaded+pgo+lto-full",
        },
        "compatible_with": [
            "@platforms//os:macos",
            "@platforms//cpu:x86_64",
        ],
        "register_exec_tools": True,
    },
    "x86_64-unknown-linux-gnu": {
        "asset_suffixes": {
            "install_only": "install_only",
            "freethreaded": "freethreaded+pgo+lto-full",
        },
        "compatible_with": [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
        "register_exec_tools": True,
        "target_settings": {
            PLATFORM_LIBC_FLAG: "glibc",
        },
    },
    "x86_64-unknown-linux-musl": {
        "asset_suffixes": {
            "install_only": "install_only",
            "freethreaded": "freethreaded+lto-full",
        },
        "compatible_with": [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
        "register_exec_tools": False,
        "target_settings": {
            PLATFORM_LIBC_FLAG: "musl",
        },
    },
    "x86_64-pc-windows-msvc": {
        "asset_suffixes": {
            "install_only": "install_only",
            "freethreaded": "freethreaded+pgo-full",
        },
        "compatible_with": [
            "@platforms//os:windows",
            "@platforms//cpu:x86_64",
        ],
        "register_exec_tools": True,
    },
    "aarch64-pc-windows-msvc": {
        "asset_suffixes": {
            "install_only": "install_only",
            "freethreaded": "freethreaded+pgo-full",
        },
        "compatible_with": [
            "@platforms//os:windows",
            "@platforms//cpu:aarch64",
        ],
        "register_exec_tools": True,
    },
    "i686-pc-windows-msvc": {
        "asset_suffixes": {
            "install_only": "install_only",
            "freethreaded": "freethreaded+pgo-full",
        },
        "compatible_with": [
            "@platforms//os:windows",
            "@platforms//cpu:x86_32",
        ],
        "register_exec_tools": True,
    },
}

# PBS build configurations registered by this extension. Keep exactly one
# target archive for each freethreaded value. Exec-tools registrations are
# emitted separately for platforms whose artifacts are supported on executors.
# Each config specifies:
# - extension: the archive file extension
# - strip_prefix: the prefix to strip when extracting
# - freethreaded: whether this is a free-threaded build
#
# buildifier: disable=unsorted-dict-items
BUILD_CONFIGS = {
    "install_only": {
        "extension": "tar.gz",
        "strip_prefix": "python",
        "freethreaded": False,
    },
    "freethreaded": {
        "extension": "tar.zst",
        "strip_prefix": "python/install",
        "freethreaded": True,
    },
}
