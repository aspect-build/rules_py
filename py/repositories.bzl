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
# buildifier: disable=function-docstring
def rules_py_dependencies():
    # The minimal version of bazel_skylib we require
    http_archive(
        name = "bazel_skylib",
        sha256 = "de9d2cedea7103d20c93a5cc7763099728206bd5088342d0009315913a592cc0",
        strip_prefix = "bazel-skylib-1.4.2",
        url = "https://github.com/bazelbuild/bazel-skylib/archive/refs/tags/1.4.2.tar.gz",
    )

    http_archive(
        name = "aspect_bazel_lib",
        sha256 = "218c4861c13692d27fa8cecd18c281850c43d1b8badae5a79893ab79120a7efb",
        strip_prefix = "bazel-lib-1.38.1",
        url = "https://github.com/aspect-build/bazel-lib/archive/refs/tags/v1.38.1.tar.gz",
    )

    # We require #1671 which isn't in a release as of 19 Jan 2024
    http_archive(
        name = "rules_python",
        sha256 = "a587c414d5aaca04841250d8809b2e21e0d89fda2597fad907419c47eeab8ab0",
        strip_prefix = "rules_python-52381415be9d3618130f02a821aef50de1e3af09",
        url = "https://github.com/bazelbuild/rules_python/archive/52381415be9d3618130f02a821aef50de1e3af09.tar.gz",
    )
