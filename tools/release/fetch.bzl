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
        sha256 = "b7cd301ef7b0ece28d20d3e778697a5e3b81828393150bed04838c0c52963a01",
        strip_prefix = "toolchains_llvm-0.10.3",
        canonical_id = "0.10.3",
        url = "https://github.com/grailbio/bazel-toolchain/releases/download/0.10.3/toolchains_llvm-0.10.3.tar.gz",
        patches = ["//third_party/com.github/bazel-contrib/toolchains_llvm:clang_ldd.patch"],
        patch_args = ["-p1"],
    )

    http_archive(
        name = "org_chromium_sysroot_linux_arm64",
        build_file_content = _SYSROOT_LINUX_BUILD_FILE,
        sha256 = "b199942a0bd9c34800e8d7b669778ef45f2054b9f106039439383dd66efcef31",
        urls = ["https://github.com/DavidZbarsky-at/sysroot-min/releases/download/v0.0.20/debian_bullseye_arm64_sysroot.tar.xz"],
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
