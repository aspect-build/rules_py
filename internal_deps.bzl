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
        sha256 = "80a98277ad1311dacd837f9b16db62887702e9f1d1c4c9f796d0121a46c8e184",
        urls = [
            "https://mirror.bazel.build/github.com/bazelbuild/rules_go/releases/download/v0.46.0/rules_go-v0.46.0.zip",
            "https://github.com/bazelbuild/rules_go/releases/download/v0.46.0/rules_go-v0.46.0.zip",
        ],
    )

    http_archive(
        name = "bazel_gazelle",
        sha256 = "75df288c4b31c81eb50f51e2e14f4763cb7548daae126817247064637fd9ea62",
        urls = [
            "https://mirror.bazel.build/github.com/bazelbuild/bazel-gazelle/releases/download/v0.36.0/bazel-gazelle-v0.36.0.tar.gz",
            "https://github.com/bazelbuild/bazel-gazelle/releases/download/v0.36.0/bazel-gazelle-v0.36.0.tar.gz",
        ],
    )

    # Override bazel_skylib distribution to fetch sources instead
    # so that the gazelle extension is included
    # see https://github.com/bazelbuild/bazel-skylib/issues/250
    http_archive(
        name = "bazel_skylib",
        sha256 = "e3fea03ff75a9821e84199466799ba560dbaebb299c655b5307f4df1e5970696",
        strip_prefix = "bazel-skylib-1.7.1",
        url = "https://github.com/bazelbuild/bazel-skylib/archive/refs/tags/1.7.1.tar.gz",
    )

    http_archive(
        name = "bazel_skylib_gazelle_plugin",
        sha256 = "747addf3f508186234f6232674dd7786743efb8c68619aece5fb0cac97b8f415",
        urls = [
            "https://mirror.bazel.build/github.com/bazelbuild/bazel-skylib/releases/download/1.5.0/bazel-skylib-gazelle-plugin-1.5.0.tar.gz",
            "https://github.com/bazelbuild/bazel-skylib/releases/download/1.5.0/bazel-skylib-gazelle-plugin-1.5.0.tar.gz",
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

    HERMETIC_CC_TOOLCHAIN_VERSION = "v2.2.1"

    http_archive(
        name = "hermetic_cc_toolchain",
        sha256 = "3b8107de0d017fe32e6434086a9568f97c60a111b49dc34fc7001e139c30fdea",
        urls = [
            "https://mirror.bazel.build/github.com/uber/hermetic_cc_toolchain/releases/download/{0}/hermetic_cc_toolchain-{0}.tar.gz".format(HERMETIC_CC_TOOLCHAIN_VERSION),
            "https://github.com/uber/hermetic_cc_toolchain/releases/download/{0}/hermetic_cc_toolchain-{0}.tar.gz".format(HERMETIC_CC_TOOLCHAIN_VERSION),
        ],
    )

    http_archive(
        name = "io_bazel_rules_docker",
        sha256 = "9d41cbe09688d4de137b19091f162de05be9a629a4355bfc1a993f378231730a",
        strip_prefix = "rules_docker-3040e1fd74659a52d1cdaff81359f57ee0e2bb41",
        urls = ["https://github.com/bazelbuild/rules_docker/archive/3040e1fd74659a52d1cdaff81359f57ee0e2bb41.zip"],
    )

    http_archive(
        name = "rules_python_gazelle_plugin",
        sha256 = "c68bdc4fbec25de5b5493b8819cfc877c4ea299c0dcb15c244c5a00208cde311",
        strip_prefix = "rules_python-0.31.0/gazelle",
        url = "https://github.com/bazelbuild/rules_python/releases/download/0.31.0/rules_python-0.31.0.tar.gz",
    )

    http_archive(
        name = "rules_rust",
        integrity = "sha256-heIBNyerJvsiq9/+SyrAwnotW2KWFnumPY9uExQPUfk=",
        urls = ["https://github.com/bazelbuild/rules_rust/releases/download/0.53.0/rules_rust-v0.53.0.tar.gz"],
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
