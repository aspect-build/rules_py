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
        sha256 = "7b39d9f38b82260a8151b18dd4a6219d2d7fc4a0ac313d4f5a630ae6907d205d",
        strip_prefix = "bazel-lib-2.10.0",
        url = "https://github.com/bazel-contrib/bazel-lib/releases/download/v2.10.0/bazel-lib-v2.10.0.tar.gz",
    )

    # from https://github.com/bazelbuild/bazel-central-registry/tree/main/modules/gawk/5.3.2.bcr.1
    http_archive(
        name = "gawk",
        remote_file_urls = {
            "BUILD.bazel": ["https://raw.githubusercontent.com/bazelbuild/bazel-central-registry/refs/heads/main/modules/gawk/5.3.2.bcr.1/overlay/BUILD.bazel"],
            "MODULE.bazel": ["https://raw.githubusercontent.com/bazelbuild/bazel-central-registry/refs/heads/main/modules/gawk/5.3.2.bcr.1/overlay/MODULE.bazel"],
            "posix/config_darwin.h": ["https://raw.githubusercontent.com/bazelbuild/bazel-central-registry/refs/heads/main/modules/gawk/5.3.2.bcr.1/overlay/posix/config_darwin.h"],
            "posix/config_linux.h": ["https://raw.githubusercontent.com/bazelbuild/bazel-central-registry/refs/heads/main/modules/gawk/5.3.2.bcr.1/overlay/posix/config_linux.h"],
            "test/BUILD.bazel": ["https://raw.githubusercontent.com/bazelbuild/bazel-central-registry/refs/heads/main/modules/gawk/5.3.2.bcr.1/overlay/test/BUILD.bazel"],
        },
        remote_file_integrity = {
            "BUILD.bazel": "sha256-dt89+9IJ3UzQvoKzyXOiBoF6ok/4u4G0cb0Ja+plFy0=",
            "MODULE.bazel": "sha256-zfjL5e51DbBLeIeMljPMdugNz0QWy+mCrDqSIvgHE8g=",
            "posix/config_darwin.h": "sha256-gPVRlvtdXPw4Ikwd5S89wPPw5AaiB2HTHa1KOtj40mU=",
            "posix/config_linux.h": "sha256-iEaeXYBUCvprsIEEi5ipwqt0JV8d73+rLgoBYTegC6Q=",
            "test/BUILD.bazel": "sha256-NktOb/GQZ8AimXwLEfGFMJB3TtgAFhobM5f9aWsHwLQ=",
        },
        url = "https://ftpmirror.gnu.org/gnu/gawk/gawk-5.3.2.tar.xz",
        strip_prefix = "gawk-5.3.2",
        integrity = "sha256-+MNIZQnecFGSE4sA7ywAu73Q6Eww1cB9I/xzqdxMycw=",
    )

    http_archive(
        name = "rules_python",
        sha256 = "c68bdc4fbec25de5b5493b8819cfc877c4ea299c0dcb15c244c5a00208cde311",
        strip_prefix = "rules_python-0.31.0",
        url = "https://github.com/bazelbuild/rules_python/releases/download/0.31.0/rules_python-0.31.0.tar.gz",
    )
