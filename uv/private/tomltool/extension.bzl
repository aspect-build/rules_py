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
        url = "https://github.com/hermeticbuild/toml2json/releases/download/v0.0.23/toml2json_darwin_arm64",
        sha256 = "6d9ac7a19c738771233192db058f74af1e6963e78147adef68d3463b6736fdd1",
    ),
    struct(
        os = "osx",
        arch = "x86_64",
        libc = "libsystem",
        url = "https://github.com/hermeticbuild/toml2json/releases/download/v0.0.23/toml2json_darwin_amd64",
        sha256 = "3fad1d4314fec5074b635ba3e5b31d578e2539137a017092bf364672a3c9676a",
    ),
    struct(
        os = "linux",
        arch = "aarch64",
        libc = "gnu",
        url = "https://github.com/hermeticbuild/toml2json/releases/download/v0.0.23/toml2json_linux_arm64",
        sha256 = "c64706324f99ad7109c62ef9475c58a6a7c6efc2f9c5fa1ce7750eb0cd9e8d02",
    ),
    struct(
        os = "linux",
        arch = "x86_64",
        libc = "gnu",
        url = "https://github.com/hermeticbuild/toml2json/releases/download/v0.0.23/toml2json_linux_amd64",
        sha256 = "fa7ce4deb4292a3ee93f4e47726ced6bb4e8483205e43e8daa4b05a4b77ec286",
    ),
    struct(
        os = "windows",
        arch = "x86_64",
        libc = "msvc",
        url = "https://github.com/hermeticbuild/toml2json/releases/download/v0.0.23/toml2json_windows_amd64.exe",
        sha256 = "bbc61cd6a081e490223b44f33003cb02e00301306d84fcba0cb3eaee8fb70396",
    ),
    struct(
        os = "windows",
        arch = "aarch64",
        libc = "msvc",
        url = "https://github.com/hermeticbuild/toml2json/releases/download/v0.0.23/toml2json_windows_arm64.exe",
        sha256 = "00a7101da6260926e8c23af3b802f82d3f820054fae3d86c29886545f5985a92",
    ),
]

def tomltool_impl(_):
    for tool in TOOLS:
        http_file(
            name = "toml2json_{}_{}_{}".format(tool.arch, tool.os, tool.libc),
            url = tool.url,
            sha256 = tool.sha256,
            executable = True,
        )

tomltool = module_extension(
    implementation = tomltool_impl,
    tag_classes = {},
)
