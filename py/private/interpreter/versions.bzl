"""Python-build-standalone release metadata.

This file contains platform mappings and build-configuration parsing for CPython
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
# Optimized free-threaded archives use different suffixes on macOS/GNU Linux,
# musl Linux, and Windows. These exact mappings are visible in PBS manifests:
# https://github.com/astral-sh/python-build-standalone/releases/download/20260303/SHA256SUMS
# https://github.com/astral-sh/python-build-standalone/releases/download/20251031/SHA256SUMS
#
# - freethreaded_suffix: exact PBS filename suffix for the free-threaded archive
#   (the non-free-threaded archive's suffix is chosen by the hub-level
#   build_config; see parse_build_config)
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
        "freethreaded_suffix": "freethreaded+pgo+lto-full",
        "compatible_with": [
            "@platforms//os:macos",
            "@platforms//cpu:aarch64",
        ],
        "register_exec_tools": True,
    },
    "aarch64-unknown-linux-gnu": {
        "freethreaded_suffix": "freethreaded+pgo+lto-full",
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
        "freethreaded_suffix": "freethreaded+lto-full",
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
        "freethreaded_suffix": "freethreaded+pgo+lto-full",
        "compatible_with": [
            "@platforms//os:macos",
            "@platforms//cpu:x86_64",
        ],
        "register_exec_tools": True,
    },
    "x86_64-unknown-linux-gnu": {
        "freethreaded_suffix": "freethreaded+pgo+lto-full",
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
        "freethreaded_suffix": "freethreaded+lto-full",
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
        "freethreaded_suffix": "freethreaded+pgo-full",
        "compatible_with": [
            "@platforms//os:windows",
            "@platforms//cpu:x86_64",
        ],
        "register_exec_tools": True,
    },
    "aarch64-pc-windows-msvc": {
        "freethreaded_suffix": "freethreaded+pgo-full",
        "compatible_with": [
            "@platforms//os:windows",
            "@platforms//cpu:aarch64",
        ],
        "register_exec_tools": True,
    },
    "i686-pc-windows-msvc": {
        "freethreaded_suffix": "freethreaded+pgo-full",
        "compatible_with": [
            "@platforms//os:windows",
            "@platforms//cpu:x86_32",
        ],
        "register_exec_tools": True,
    },
}

# Tokens permitted in a "-full" build configuration suffix, ranked by PBS's
# canonical filename order (e.g. "pgo+lto-full", "freethreaded+debug-full",
# "lto+static-full"). Manifests only ever use this order, so misordered or
# duplicated tokens can never match an asset and are rejected at parse time.
_FULL_TOKEN_RANK = {
    "freethreaded": 0,
    "debug": 1,
    "noopt": 2,
    "pgo": 3,
    "lto": 4,
    "static": 5,
}

def parse_build_config(suffix):
    """Decode a python-build-standalone build configuration suffix.

    PBS asset filenames end in a build configuration suffix drawn from a fixed
    grammar visible in the SHA256SUMS manifests. This parses that suffix into
    the archive and ABI properties a toolchain needs, without enumerating every
    published combination:

        install_only[_stripped]                    redistributable, tar.gz
        [freethreaded+]<opt...>[+static]-full      full archive,     tar.zst

    where each <opt> component is one of debug, noopt, pgo, lto, in that
    order (e.g. "pgo+lto-full", "debug-full", "freethreaded+pgo+lto-full").

    Availability of a given suffix for a specific version/platform is a
    separate question, resolved against the release manifest.

    Args:
        suffix: a PBS build configuration suffix, e.g. "install_only".

    Returns:
        None if the suffix does not match the grammar, else a dict with:
            suffix:        the input, unchanged (the exact filename suffix)
            extension:     archive extension ("tar.gz" or "tar.zst")
            strip_prefix:  extraction prefix ("python" or "python/install")
            abi_flags:     CPython ABI flags ("", "t", "d", or "td")
            freethreaded:  whether this is a free-threaded build
            debug:         whether this is a Py_DEBUG build
            static:        whether libpython is statically linked
    """
    if suffix in ("install_only", "install_only_stripped"):
        return {
            "suffix": suffix,
            "extension": "tar.gz",
            "strip_prefix": "python",
            "abi_flags": "",
            "freethreaded": False,
            "debug": False,
            "static": False,
        }

    if not suffix.endswith("-full"):
        return None

    tokens = suffix[:-len("-full")].split("+")
    last_rank = -1
    for token in tokens:
        rank = _FULL_TOKEN_RANK.get(token)
        if rank == None or rank <= last_rank:
            return None
        last_rank = rank
    freethreaded = "freethreaded" in tokens
    debug = "debug" in tokens
    static = "static" in tokens

    return {
        "suffix": suffix,
        "extension": "tar.zst",
        "strip_prefix": "python/install",
        "abi_flags": ("t" if freethreaded else "") + ("d" if debug else ""),
        "freethreaded": freethreaded,
        "debug": debug,
        "static": static,
    }

def validate_build_config(suffix):
    """Validate a hub-level build_config.

    Fails with an actionable message when the configuration is unrecognized or
    cannot back a working non-free-threaded runtime toolchain.

    Args:
        suffix: the build_config attribute value from interpreters.configure().

    Returns:
        The parse_build_config() dict for the suffix.
    """
    parsed = parse_build_config(suffix)
    if parsed == None:
        fail(
            "Unrecognized PBS build_config '{}'. ".format(suffix) +
            "Expected 'install_only', 'install_only_stripped', or a " +
            "'<opt>[+<opt>...]-full' suffix where each component is one of " +
            "debug, noopt, pgo, lto — at most once and in that order, as PBS " +
            "publishes them (e.g. 'pgo+lto-full', 'debug-full'). " +
            "See https://github.com/astral-sh/python-build-standalone/releases.",
        )
    if parsed["static"]:
        fail(
            "build_config '{}' selects a statically linked libpython. ".format(suffix) +
            "Extension modules resolve Python symbols from the loading " +
            "interpreter, so a static build cannot back a runtime toolchain. " +
            "Use a non-static build configuration.",
        )
    if parsed["freethreaded"]:
        # Bare "freethreaded-full" has no non-free-threaded counterpart, so
        # only offer an example when dropping the token leaves a valid suffix.
        alternative = suffix.replace("freethreaded+", "")
        example = " (e.g. '{}')".format(alternative) if alternative != suffix else ""
        fail(
            "build_config '{}' must not select free-threading. ".format(suffix) +
            "Free-threading is an orthogonal axis chosen at build time via " +
            "--@aspect_rules_py//py/private/interpreter:freethreaded; pass the " +
            "non-free-threaded suffix instead{}.".format(example),
        )
    return parsed
