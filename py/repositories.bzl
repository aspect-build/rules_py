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
        sha256 = "e3fea03ff75a9821e84199466799ba560dbaebb299c655b5307f4df1e5970696",
        strip_prefix = "bazel-skylib-1.7.1",
        url = "https://github.com/bazelbuild/bazel-skylib/archive/refs/tags/1.7.1.tar.gz",
    )

    # py_image_layer requires 2.x for the `tar` rule.
    http_archive(
        name = "aspect_bazel_lib",
        sha256 = "349aabd3c2b96caeda6181eb0ae1f14f2a1d9f3cd3c8b05d57f709ceb12e9fb3",
        strip_prefix = "bazel-lib-2.9.4",
        url = "https://github.com/bazel-contrib/bazel-lib/releases/download/v2.9.4/bazel-lib-v2.9.4.tar.gz",
    )

    http_archive(
        name = "rules_python",
        sha256 = "c68bdc4fbec25de5b5493b8819cfc877c4ea299c0dcb15c244c5a00208cde311",
        strip_prefix = "rules_python-0.31.0",
        url = "https://github.com/bazelbuild/rules_python/releases/download/0.31.0/rules_python-0.31.0.tar.gz",
    )