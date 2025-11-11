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
        url = "https://github.com/dzbarsky/toml2json/releases/download/v0.0.4/toml2json_darwin_arm64",
        sha256 = "9adc44d976e8f5baf5a6d613ceb3db6e5f56b2e22e75ac56521fdce62f227d88",
    ),
    struct(
        os = "osx",
        arch = "x86_64",
        libc = "libsystem",
        url = "https://github.com/dzbarsky/toml2json/releases/download/v0.0.4/toml2json_darwin_amd64",
        sha256 = "425bac4015394fd9840fabcd52ac60fc796a9c10655b36c57e36ffb7dc9f3dd4",
    ),
    struct(
        os = "linux",
        arch = "aarch64",
        libc = "gnu",
        url = "https://github.com/dzbarsky/toml2json/releases/download/v0.0.4/toml2json_linux_arm64",
        sha256 = "be8376c8e3232a242eae0d187f741a475498a949b942361a9af6e95072ef5670",
    ),
    struct(
        os = "linux",
        arch = "x86_64",
        libc = "gnu",
        url = "https://github.com/dzbarsky/toml2json/releases/download/v0.0.4/toml2json_linux_amd64",
        sha256 = "f3dd54fabf2d27d0c027b0421860e5d9d909080be1613f0ffd87057633b65e9a",
    ),
    struct(
        os = "windows",
        arch = "aarch64",
        libc = "msvc",
        url = "https://github.com/peakschris/toml2json/releases/download/v0.0.9/toml2json_windows_arm64.exe",
        sha256 = "c977f42491d2912c57e5678f4894bb45f7fbaa93158dd3189537fed6dbf8d0cc",
    ),
    struct(
        os = "windows",
        arch = "x86_64",
        libc = "msvc",
        url = "https://github.com/peakschris/toml2json/releases/download/v0.0.9/toml2json_windows_amd64.exe",
        sha256 = "b434ce11d75f3040eefcbcdf43cea469c28e72455cc48f3cdd7246d1a2f08ddc",
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
