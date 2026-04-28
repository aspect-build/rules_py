"""
Materialize a `tomltool` binary we can use for decoding to JSON.

A slight improvement on multitool which:
1. Fetches exactly one binary for the current host configuration
2. Is libc aware, unlike multitool
"""

load("@bazel_features//:features.bzl", features = "bazel_features")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")

TOOLS = [
    struct(
        os = "osx",
        arch = "aarch64",
        libc = "libsystem",
        url = "https://github.com/hermeticbuild/toml2json/releases/download/v0.0.26/toml2json_darwin_arm64",
        sha256 = "13e000bb10f66fd3eb7e72c1fbb382a72859fefb9a75b99173728b0136bd932f",
    ),
    struct(
        os = "osx",
        arch = "x86_64",
        libc = "libsystem",
        url = "https://github.com/hermeticbuild/toml2json/releases/download/v0.0.26/toml2json_darwin_amd64",
        sha256 = "632da497331d7aa5f2dd36b7c3c4339639e203bbafa56db77f0bb46cf46089a6",
    ),
    struct(
        os = "linux",
        arch = "aarch64",
        libc = "gnu",
        url = "https://github.com/hermeticbuild/toml2json/releases/download/v0.0.26/toml2json_linux_arm64",
        sha256 = "b271e043e58814353a3f289fb7ce78198d742e730149325d0622d71f3d8595b5",
    ),
    struct(
        os = "linux",
        arch = "x86_64",
        libc = "gnu",
        url = "https://github.com/hermeticbuild/toml2json/releases/download/v0.0.26/toml2json_linux_amd64",
        sha256 = "87921b36ceb343af152fc988be59eec49ac9865f2e499a48152bed03e66f8228",
    ),
    struct(
        os = "windows",
        arch = "x86_64",
        libc = "msvc",
        url = "https://github.com/hermeticbuild/toml2json/releases/download/v0.0.26/toml2json_windows_amd64.exe",
        sha256 = "3fb037472c7ec2485b1c965253404841bfa32d571489b76dfbbc1c7ad6848884",
    ),
    struct(
        os = "windows",
        arch = "aarch64",
        libc = "msvc",
        url = "https://github.com/hermeticbuild/toml2json/releases/download/v0.0.26/toml2json_windows_arm64.exe",
        sha256 = "f825f7b6aea181bb050d4112d3234ec4ef0de45fadc9e6f99c0adcb08db9cf64",
    ),
]

def tomltool_impl(module_ctx):
    for tool in TOOLS:
        http_file(
            name = "toml2json_{}_{}_{}".format(tool.arch, tool.os, tool.libc),
            url = tool.url,
            sha256 = tool.sha256,
            executable = True,
        )

    if not features.external_deps.extension_metadata_has_reproducible:
        return None
    return module_ctx.extension_metadata(reproducible = True)

tomltool = module_extension(
    implementation = tomltool_impl,
    tag_classes = {},
)
