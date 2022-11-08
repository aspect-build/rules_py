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
        sha256 = "3b620033ca48fcd6f5ef2ac85e0f6ec5639605fa2f627968490e52fc91a9932f",
        strip_prefix = "bazel-skylib-1.3.0",
        url = "https://github.com/bazelbuild/bazel-skylib/archive/refs/tags/1.3.0.tar.gz",
    )

    http_archive(
        name = "aspect_bazel_lib",
        sha256 = "3534a27621725fbbf1d3e53daa0c1dda055a2732d9031b8c579f917d7347b6c4",
        strip_prefix = "bazel-lib-1.16.1",
        url = "https://github.com/aspect-build/bazel-lib/archive/refs/tags/v1.16.1.tar.gz",
    )

    http_archive(
        name = "rules_python",
        patch_cmds = ["""\
cat >> python/BUILD <<EOF
load("@bazel_skylib//:bzl_library.bzl", "bzl_library")

bzl_library(
    name = "defs",
    srcs = [":bzl"],
    deps = [
        "@bazel_tools//tools/python:srcs_version.bzl",
        "@bazel_tools//tools/python:utils.bzl",
        "@bazel_tools//tools/python:private/defs.bzl",
        "@bazel_tools//tools/python:toolchain.bzl",
    ],
    visibility = ["//visibility:public"],
)
EOF
"""],
        sha256 = "8c8fe44ef0a9afc256d1e75ad5f448bb59b81aba149b8958f02f7b3a98f5d9b4",
        strip_prefix = "rules_python-0.13.0",
        url = "https://github.com/bazelbuild/rules_python/archive/refs/tags/0.13.0.tar.gz",
    )
