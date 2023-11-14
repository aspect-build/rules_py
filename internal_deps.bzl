"""Our "development" dependencies

Users should *not* need to install these. If users see a load()
statement from these, that's a bug in our distribution.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file", _http_archive = "http_archive")
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
        sha256 = "278b7ff5a826f3dc10f04feaf0b70d48b68748ccd512d7f98bf442077f043fe3",
        urls = [
            "https://mirror.bazel.build/github.com/bazelbuild/rules_go/releases/download/v0.41.0/rules_go-v0.41.0.zip",
            "https://github.com/bazelbuild/rules_go/releases/download/v0.41.0/rules_go-v0.41.0.zip",
        ],
    )

    http_archive(
        name = "bazel_gazelle",
        sha256 = "b7387f72efb59f876e4daae42f1d3912d0d45563eac7cb23d1de0b094ab588cf",
        urls = [
            "https://mirror.bazel.build/github.com/bazelbuild/bazel-gazelle/releases/download/v0.34.0/bazel-gazelle-v0.34.0.tar.gz",
            "https://github.com/bazelbuild/bazel-gazelle/releases/download/v0.34.0/bazel-gazelle-v0.34.0.tar.gz",
        ],
    )

    # Override bazel_skylib distribution to fetch sources instead
    # so that the gazelle extension is included
    # see https://github.com/bazelbuild/bazel-skylib/issues/250
    http_archive(
        name = "bazel_skylib",
        sha256 = "de9d2cedea7103d20c93a5cc7763099728206bd5088342d0009315913a592cc0",
        strip_prefix = "bazel-skylib-1.4.2",
        url = "https://github.com/bazelbuild/bazel-skylib/archive/refs/tags/1.4.2.tar.gz",
    )

    http_archive(
        name = "bazel_skylib_gazelle_plugin",
        sha256 = "3327005dbc9e49cc39602fb46572525984f7119a9c6ffe5ed69fbe23db7c1560",
        urls = [
            "https://mirror.bazel.build/github.com/bazelbuild/bazel-skylib/releases/download/1.4.2/bazel-skylib-gazelle-plugin-1.4.2.tar.gz",
            "https://github.com/bazelbuild/bazel-skylib/releases/download/1.4.2/bazel-skylib-gazelle-plugin-1.4.2.tar.gz",
        ],
    )

    http_archive(
        name = "io_bazel_stardoc",
        sha256 = "3fd8fec4ddec3c670bd810904e2e33170bedfe12f90adf943508184be458c8bb",
        urls = [
            "https://mirror.bazel.build/github.com/bazelbuild/stardoc/releases/download/0.5.3/stardoc-0.5.3.tar.gz",
            "https://github.com/bazelbuild/stardoc/releases/download/0.5.3/stardoc-0.5.3.tar.gz",
        ],
    )

    # Aspect gcc toolchain for RBE
    http_archive(
        name = "aspect_gcc_toolchain",
        sha256 = "b843608fccbbd163071be0463c82e18f3b96ba220fafe4b46e5ffe8579664390",
        urls = [
            "https://github.com/aspect-build/gcc-toolchain/archive/70a8c93b7f84077b1d952647ef967d8ae55554c8.zip",
        ],
        strip_prefix = "gcc-toolchain-70a8c93b7f84077b1d952647ef967d8ae55554c8",
    )

    http_archive(
        name = "io_bazel_rules_docker",
        sha256 = "cd42f44e219a4f1fc5c18a0702330505b94e3abd64c3e21d38ea25a6ab42dad6",
        strip_prefix = "rules_docker-8e70c6bcb584a15a8fd061ea489b933c0ff344ca",
        urls = ["https://github.com/bazelbuild/rules_docker/archive/8e70c6bcb584a15a8fd061ea489b933c0ff344ca.zip"],
    )

    http_archive(
        name = "rules_python_gazelle_plugin",
        sha256 = "36362b4d54fcb17342f9071e4c38d63ce83e2e57d7d5599ebdde4670b9760664",
        strip_prefix = "rules_python-0.18.0/gazelle",
        url = "https://github.com/bazelbuild/rules_python/releases/download/0.18.0/rules_python-0.18.0.tar.gz",
    )

    http_file(
        name = "django_4_2_4",
        urls = ["https://files.pythonhosted.org/packages/7f/9e/fc6bab255ae10bc57fa2f65646eace3d5405fbb7f5678b90140052d1db0f/Django-4.2.4-py3-none-any.whl"],
        sha256 = "860ae6a138a238fc4f22c99b52f3ead982bb4b1aad8c0122bcd8c8a3a02e409d",
        downloaded_file_path = "Django-4.2.4-py3-none-any.whl",
    )

    http_file(
        name = "django_4_1_10",
        urls = ["https://files.pythonhosted.org/packages/34/25/8a218de57fc9853297a1a8e4927688eff8107d5bc6dcf6c964c59801f036/Django-4.1.10-py3-none-any.whl"],
        sha256 = "26d0260c2fb8121009e62ffc548b2398dea2522b6454208a852fb0ef264c206c",
        downloaded_file_path = "Django-4.1.10-py3-none-any.whl",
    )

    http_file(
        name = "sqlparse_0_4_0",
        urls = ["https://files.pythonhosted.org/packages/10/96/36c136013c4a6ecb8c6aa3eed66e6dcea838f85fd80e1446499f1dabfac7/sqlparse-0.4.0-py3-none-any.whl"],
        sha256 = "0523026398aea9c8b5f7a4a6d5c0829c285b4fbd960c17b5967a369342e21e01",
        downloaded_file_path = "sqlparse-0.4.0-py3-none-any.whl",
    )
