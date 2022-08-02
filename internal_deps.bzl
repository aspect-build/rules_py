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
        sha256 = "685052b498b6ddfe562ca7a97736741d87916fe536623afb7da2824c0211c369",
        urls = [
            "https://mirror.bazel.build/github.com/bazelbuild/rules_go/releases/download/v0.33.0/rules_go-v0.33.0.zip",
            "https://github.com/bazelbuild/rules_go/releases/download/v0.33.0/rules_go-v0.33.0.zip",
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
        sha256 = "07b4117379dde7ab382345c3b0f5edfc6b7cff6c93756eac63da121e0bbcc5de",
        strip_prefix = "bazel-skylib-1.1.1",
        urls = [
            "https://mirror.bazel.build/github.com/bazelbuild/bazel-skylib/archive/1.1.1.tar.gz",
            "https://github.com/bazelbuild/bazel-skylib/archive/refs/tags/1.1.1.tar.gz",
        ],
    )

    http_archive(
        name = "io_bazel_stardoc",
        sha256 = "c9794dcc8026a30ff67cf7cf91ebe245ca294b20b071845d12c192afe243ad72",
        urls = [
            "https://mirror.bazel.build/github.com/bazelbuild/stardoc/releases/download/0.5.0/stardoc-0.5.0.tar.gz",
            "https://github.com/bazelbuild/stardoc/releases/download/0.5.0/stardoc-0.5.0.tar.gz",
        ],
    )

    # Aspect gcc toolchain for RBE
    http_archive(
        name = "aspect_gcc_toolchain",
        sha256 = "3de17d64f5a9b1d4e02dd90473f1d88cdb236ed15eea54601a0aa44f3c109893",
        urls = [
            "https://github.com/aspect-build/gcc-toolchain/archive/01f4347af9cbb24866915404e40b7c85107a2334.zip",
        ],
        strip_prefix = "gcc-toolchain-01f4347af9cbb24866915404e40b7c85107a2334",
    )

    http_archive(
        name = "io_bazel_rules_docker",
        sha256 = "ff3647e5c9dd570e06a2ef9854800ea7fd665e4189005c130f1ae7554337a7e8",
        strip_prefix = "rules_docker-a8aff4076f75c4dfb39bd768dd9870b5d263e70d",
        urls = ["https://github.com/bazelbuild/rules_docker/archive/a8aff4076f75c4dfb39bd768dd9870b5d263e70d.zip"],
    )
