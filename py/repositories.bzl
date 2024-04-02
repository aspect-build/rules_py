"""Declare runtime dependencies

These are needed for local dev, and users must install them as well.
See https://docs.bazel.build/versions/main/skylark/deploying.html#dependencies
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", _http_archive = "http_archive")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")

def http_archive(name, **kwargs):
    maybe(_http_archive, name = name, **kwargs)


# WARNING: any changes in this function may be BREAKING CHANGES for users
# because we'll fetch a dependency which may be different from one that
# they were previously fetching later in their WORKSPACE setup, and now
# ours took precedence. Such breakages are challenging for users, so any
# changes in this function should be marked as BREAKING in the commit message
# and released only in semver majors.

# buildifier: disable=unnamed-macro
def rules_py_dependencies():
    """Fetch rules_py's dependencies"""

    # The minimal version of bazel_skylib we require
    http_archive(
        name = "bazel_skylib",
        sha256 = "118e313990135890ee4cc8504e32929844f9578804a1b2f571d69b1dd080cfb8",
        strip_prefix = "bazel-skylib-1.5.0",
        url = "https://github.com/bazelbuild/bazel-skylib/archive/refs/tags/1.5.0.tar.gz",
    )

    http_archive(
        name = "aspect_bazel_lib",
        sha256 = "f9a0bb072aef719859aae5ad37722e97812ffffb263fd56a36cd8614a2e5d199",
        strip_prefix = "bazel-lib-1.42.2",
        url = "https://github.com/aspect-build/bazel-lib/releases/download/v1.42.2/bazel-lib-v1.42.2.tar.gz",
    )

    http_archive(
        name = "rules_python",
        sha256 = "c68bdc4fbec25de5b5493b8819cfc877c4ea299c0dcb15c244c5a00208cde311",
        strip_prefix = "rules_python-0.31.0",
        url = "https://github.com/bazelbuild/rules_python/releases/download/0.31.0/rules_python-0.31.0.tar.gz",
    )