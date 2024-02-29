"""Declare runtime dependencies

These are needed for local dev, and users must install them as well.
See https://docs.bazel.build/versions/main/skylark/deploying.html#dependencies
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", _http_archive = "http_archive")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")
load("//py/private/toolchain:autodetecting.bzl", _register_autodetecting_python_toolchain = "register_autodetecting_python_toolchain")

def http_archive(name, **kwargs):
    maybe(_http_archive, name = name, **kwargs)

register_autodetecting_python_toolchain = _register_autodetecting_python_toolchain

# WARNING: any changes in this function may be BREAKING CHANGES for users
# because we'll fetch a dependency which may be different from one that
# they were previously fetching later in their WORKSPACE setup, and now
# ours took precedence. Such breakages are challenging for users, so any
# changes in this function should be marked as BREAKING in the commit message
# and released only in semver majors.

# buildifier: disable=unnamed-macro
def rules_py_dependencies(register_py_toolchains = True):
    """Fetch rules_py's dependencies, and optionally register toolchains.

    Args:
        register_py_toolchains: When true, rules_py's toolchains are automatically registered.
    """

    # The minimal version of bazel_skylib we require
    http_archive(
        name = "bazel_skylib",
        sha256 = "118e313990135890ee4cc8504e32929844f9578804a1b2f571d69b1dd080cfb8",
        strip_prefix = "bazel-skylib-1.5.0",
        url = "https://github.com/bazelbuild/bazel-skylib/archive/refs/tags/1.5.0.tar.gz",
    )

    http_archive(
        name = "aspect_bazel_lib",
        sha256 = "40bbabf754d1cb538be53f7c74821cc4a2f1002fa1d4608d85c75fff3ccce78c",
        strip_prefix = "bazel-lib-1.40.0",
        url = "https://github.com/aspect-build/bazel-lib/archive/refs/tags/v1.40.0.tar.gz",
    )

    http_archive(
        name = "rules_python",
        sha256 = "c68bdc4fbec25de5b5493b8819cfc877c4ea299c0dcb15c244c5a00208cde311",
        strip_prefix = "rules_python-0.31.0",
        url = "https://github.com/bazelbuild/rules_python/releases/download/0.31.0/rules_python-0.31.0.tar.gz",
    )

    if register_py_toolchains:
        native.register_toolchains(
            "@aspect_rules_py//py/private/toolchain/venv/...",
            "@aspect_rules_py//py/private/toolchain/unpack/...",
        )
