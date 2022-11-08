"""Our "development" dependencies

Users should *not* need to install these. If users see a load()
statement from these, that's a bug in our distribution.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", _http_archive = "http_archive")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")

def http_archive(name, **kwargs):
    maybe(_http_archive, name = name, **kwargs)

def rules_py_internal_deps():
    "Fetch deps needed for local development"
    http_archive(
        name = "build_bazel_integration_testing",
        urls = [
            "https://github.com/bazelbuild/bazel-integration-testing/archive/7d3e9aee60e2320b1987b871cfaa85b0fca4fdd5.zip",
        ],
        strip_prefix = "bazel-integration-testing-7d3e9aee60e2320b1987b871cfaa85b0fca4fdd5",
        sha256 = "f4abdacd838a10a2ac01b813664a53ddf684bb3fedf25dc35765725740cc85e3",
    )

    http_archive(
        name = "io_bazel_rules_go",
        sha256 = "16e9fca53ed6bd4ff4ad76facc9b7b651a89db1689a2877d6fd7b82aa824e366",
        urls = [
            "https://mirror.bazel.build/github.com/bazelbuild/rules_go/releases/download/v0.34.0/rules_go-v0.34.0.zip",
            "https://github.com/bazelbuild/rules_go/releases/download/v0.34.0/rules_go-v0.34.0.zip",
        ],
    )

    http_archive(
        name = "bazel_gazelle",
        sha256 = "501deb3d5695ab658e82f6f6f549ba681ea3ca2a5fb7911154b5aa45596183fa",
        urls = [
            "https://mirror.bazel.build/github.com/bazelbuild/bazel-gazelle/releases/download/v0.26.0/bazel-gazelle-v0.26.0.tar.gz",
            "https://github.com/bazelbuild/bazel-gazelle/releases/download/v0.26.0/bazel-gazelle-v0.26.0.tar.gz",
        ],
    )

    # Override bazel_skylib distribution to fetch sources instead
    # so that the gazelle extension is included
    # see https://github.com/bazelbuild/bazel-skylib/issues/250
    http_archive(
        name = "bazel_skylib",
        sha256 = "3b620033ca48fcd6f5ef2ac85e0f6ec5639605fa2f627968490e52fc91a9932f",
        strip_prefix = "bazel-skylib-1.3.0",
        urls = [
            "https://mirror.bazel.build/github.com/bazelbuild/bazel-skylib/archive/1.3.0.tar.gz",
            "https://github.com/bazelbuild/bazel-skylib/archive/refs/tags/1.3.0.tar.gz",
        ],
    )

    http_archive(
        name = "io_bazel_stardoc",
        sha256 = "05fb57bb4ad68a360470420a3b6f5317e4f722839abc5b17ec4ef8ed465aaa47",
        urls = [
            "https://mirror.bazel.build/github.com/bazelbuild/stardoc/releases/download/0.5.2/stardoc-0.5.2.tar.gz",
            "https://github.com/bazelbuild/stardoc/releases/download/0.5.2/stardoc-0.5.2.tar.gz",
        ],
    )

    # Aspect gcc toolchain for RBE
    http_archive(
        name = "aspect_gcc_toolchain",
        sha256 = "79c99023146b52935255f09479395135db1dc3f6236a8d78f4e425518562d40d",
        urls = [
            "https://github.com/aspect-build/gcc-toolchain/archive/0e000705bb61614903ba2b28964a93ec0177b5ee.zip",
        ],
        strip_prefix = "gcc-toolchain-0e000705bb61614903ba2b28964a93ec0177b5ee",
    )

    http_archive(
        name = "io_bazel_rules_docker",
        sha256 = "ff3647e5c9dd570e06a2ef9854800ea7fd665e4189005c130f1ae7554337a7e8",
        strip_prefix = "rules_docker-a8aff4076f75c4dfb39bd768dd9870b5d263e70d",
        urls = ["https://github.com/bazelbuild/rules_docker/archive/a8aff4076f75c4dfb39bd768dd9870b5d263e70d.zip"],
    )
