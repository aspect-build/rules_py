"Dependencies only needed for release builds"

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

_SYSROOT_LINUX_BUILD_FILE = """
filegroup(
    name = "sysroot",
    srcs = glob(["*/**"]),
    visibility = ["//visibility:public"],
)
"""

_SYSROOT_DARWIN_BUILD_FILE = """
filegroup(
    name = "sysroot",
    srcs = glob(
        include = ["**"],
        exclude = ["**/*:*"],
    ),
    visibility = ["//visibility:public"],
)
"""

def fetch_deps():
    http_archive(
        name = "toolchains_llvm",
        sha256 = "e91c4361f99011a54814e1afbe5c436e0d329871146a3cd58c23a2b4afb50737",
        strip_prefix = "toolchains_llvm-1.0.0",
        canonical_id = "0.10.3",
        url = "https://github.com/grailbio/bazel-toolchain/releases/download/1.0.0/toolchains_llvm-1.0.0.tar.gz",
        patches = ["//third_party/com.github/bazel-contrib/toolchains_llvm:clang_ldd.patch"],
        patch_args = ["-p1"],
    )

    http_archive(
        name = "org_chromium_sysroot_linux_arm64",
        build_file_content = _SYSROOT_LINUX_BUILD_FILE,
        sha256 = "63dfb6585e58f6e11cd2323d52c9099a5122beca2fddd0d9beda7e869a3b8f67",
        urls = ["https://github.com/DavidZbarsky-at/sysroot-min/releases/download/v0.0.19/debian_bullseye_arm64_sysroot.tar.xz"],
    )

    http_archive(
        name = "org_chromium_sysroot_linux_x86_64",
        build_file_content = _SYSROOT_LINUX_BUILD_FILE,
        sha256 = "4e8f85b2f349eb95e28e845183c135fddef58c02f14559065f5818a7e9216971",
        urls = ["https://github.com/DavidZbarsky-at/sysroot-min/releases/download/v0.0.19/debian_bullseye_amd64_sysroot.tar.xz"],
    )

    http_archive(
        name = "sysroot_darwin_universal",
        build_file_content = _SYSROOT_DARWIN_BUILD_FILE,
        sha256 = "11870a4a3d382b78349861081264921bb883440a7e0b3dd4a007373d87324a38",
        strip_prefix = "sdk-macos-11.3-ccbaae84cc39469a6792108b24480a4806e09d59/root",
        urls = ["https://github.com/hexops-graveyard/sdk-macos-11.3/archive/ccbaae84cc39469a6792108b24480a4806e09d59.tar.gz"],
    )
