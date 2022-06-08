"""Declare runtime dependencies

These are needed for local dev, and users must install them as well.
See https://docs.bazel.build/versions/main/skylark/deploying.html#dependencies
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")
load("//py/private/toolchain:autodetecting.bzl", _register_autodetecting_python_toolchain = "register_autodetecting_python_toolchain")

register_autodetecting_python_toolchain = _register_autodetecting_python_toolchain

# WARNING: any changes in this function may be BREAKING CHANGES for users
# because we'll fetch a dependency which may be different from one that
# they were previously fetching later in their WORKSPACE setup, and now
# ours took precedence. Such breakages are challenging for users, so any
# changes in this function should be marked as BREAKING in the commit message
# and released only in semver majors.
def rules_py_dependencies():
    # The minimal version of bazel_skylib we require
    maybe(
        http_archive,
        name = "bazel_skylib",
        sha256 = "c6966ec828da198c5d9adbaa94c05e3a1c7f21bd012a0b29ba8ddbccb2c93b0d",
        urls = [
            "https://github.com/bazelbuild/bazel-skylib/releases/download/1.1.1/bazel-skylib-1.1.1.tar.gz",
            "https://mirror.bazel.build/github.com/bazelbuild/bazel-skylib/releases/download/1.1.1/bazel-skylib-1.1.1.tar.gz",
        ],
    )

    maybe(
        http_archive,
        name = "aspect_bazel_lib",
        sha256 = "b381ac4dca544ecc5515916f38066e9793628477e2577edb7b2ab04e8c210738",
        strip_prefix = "bazel-lib-1.0.0",
        url = "https://github.com/aspect-build/bazel-lib/archive/refs/tags/v1.0.0.tar.gz",
    )

    maybe(
        http_archive,
        name = "rules_python",
        sha256 = "cdf6b84084aad8f10bf20b46b77cb48d83c319ebe6458a18e9d2cebf57807cdd",
        strip_prefix = "rules_python-0.8.1",
        url = "https://github.com/bazelbuild/rules_python/archive/refs/tags/0.8.1.tar.gz",
    )
