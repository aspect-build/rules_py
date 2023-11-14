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
        sha256 = "d488d8ecca98a4042442a4ae5f1ab0b614f896c0ebf6e3eafff363bcc51c6e62",
        strip_prefix = "bazel-lib-1.33.0",
        url = "https://github.com/aspect-build/bazel-lib/archive/refs/tags/v1.33.0.tar.gz",
    )

    http_archive(
        name = "rules_python",
        sha256 = "cff4c0ac0873ce089557b72828f34b82e67f35e9accfe414b5c3230907104a87",
        strip_prefix = "rules_python-9facc3e3341f156377c61afbaa1dfb79a3843b78",
        url = "https://github.com/bazelbuild/rules_python/archive/9facc3e3341f156377c61afbaa1dfb79a3843b78.tar.gz",
    )
