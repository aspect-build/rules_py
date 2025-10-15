"""
Materialize a `tomltool` binary we can use for decoding to JSON.

A slight improvement on multitool which:
1. Fetches exactly one binary for the current host configuration
2. Is libc aware, unlike multitool
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")

TOOLS = [
    struct(
        os = "osx",
        arch = "aarch64",
        libc = "libsystem",
        url = "https://github.com/aspect-build/toml.bzl/releases/download/v0.0.2/tomltool_aarch64_apple_darwin",
        sha256 = "a7648d1728cfb80e99553fcf4c4f4da72aa02d869192712eba8e61b86b237e0b",
    ),
    struct(
        os = "osx",
        arch = "x86_64",
        libc = "libsystem",
        url = "https://github.com/aspect-build/toml.bzl/releases/download/v0.0.2/tomltool_x86_64_apple_darwin",
        sha256 = "cb54250ce1393f95d080425df9e4ac926df75ed3b4f10c0642458c7b9697beb4",
    ),
    struct(
        os = "linux",
        arch = "aarch64",
        libc = "gnu",
        url = "https://github.com/aspect-build/toml.bzl/releases/download/v0.0.2/tomltool_aarch64_unknown_linux_gnu",
        sha256 = "b0790b06d69c62163689bc10dccdcb9909b88c235f6538e0bd6357247c63db47",
    ),
    struct(
        os = "linux",
        arch = "aarch64",
        libc = "musl",
        url = "https://github.com/aspect-build/toml.bzl/releases/download/v0.0.2/tomltool_aarch64_unknown_linux_musl",
        sha256 = "f303b3b1d63529d9e82b9ef19fd711f90d8fd87d4a860b383a9453bac3369139",
    ),
    struct(
        os = "linux",
        arch = "x86_64",
        libc = "gnu",
        url = "https://github.com/aspect-build/toml.bzl/releases/download/v0.0.2/tomltool_x86_64_unknown_linux_gnu",
        sha256 = "4d9426b620acffe73af53e5524ed8c8bbe15e6214c752f37c22f5479fc9e3a51",
    ),
    struct(
        os = "linux",
        arch = "x86_64",
        libc = "musl",
        url = "https://github.com/aspect-build/toml.bzl/releases/download/v0.0.2/tomltool_x86_64_unknown_linux_musl",
        sha256 = "c9b2a29dca81a4ceff9aa40049b8e5d7fafd4981f8460e81c2b3c529b95a9afa",
    ),
]

def tomltool_impl(_):
    for tool in TOOLS:
        http_file(
            name = "aspect_rules_py_tomltool_{}_{}_{}".format(tool.arch, tool.os, tool.libc),
            url = tool.url,
            sha256 = tool.sha256,
            executable = True,
        )

tomltool = module_extension(
    implementation = tomltool_impl,
    tag_classes = {},
)
