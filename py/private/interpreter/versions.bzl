"""Python-build-standalone release metadata.

This file contains URLs and SHA256 hashes for CPython interpreters built by the
python-build-standalone project (https://github.com/astral-sh/python-build-standalone).

Only non-freethreaded, install_only builds are included. Only the four primary
platforms (linux x86_64/aarch64 glibc, macOS x86_64/aarch64) are listed to
start. Additional platforms can be added as needed.
"""

DEFAULT_RELEASE_BASE_URL = "https://github.com/astral-sh/python-build-standalone/releases/download"

# buildifier: disable=unsorted-dict-items
TOOL_VERSIONS = {
    "3.11.14": {
        "url": "20251031/cpython-{python_version}+20251031-{platform}-install_only.tar.gz",
        "strip_prefix": "python",
        "sha256": {
            "aarch64-apple-darwin": "6de5572b33c65af1c9b7caf00ec593fb04cffb7e14fa393a98261bb9bc464713",
            "aarch64-unknown-linux-gnu": "510edb027527413c4249256194cb8ad2590b52dd93f7123b4cb341aff5d05894",
            "x86_64-apple-darwin": "4891cbf34e8652b7bd1054b9502395e4b7e048e2e517c040fbf6c8297cb954d6",
            "x86_64-unknown-linux-gnu": "60f0bd473d861cc45d3401d9914e47ccb9fa037f88a91879ed517a62042b8477",
            "x86_64-unknown-linux-musl": "25e82d1e85b90a8ab724ee633a1811b1921797f5c25ee69c6595052371b91a87",
        },
    },
    "3.12.12": {
        "url": "20251031/cpython-{python_version}+20251031-{platform}-install_only.tar.gz",
        "strip_prefix": "python",
        "sha256": {
            "aarch64-apple-darwin": "5e110cb821d2eb8246065d3b46faa655180c976c4e17250f7883c634a629bc63",
            "aarch64-unknown-linux-gnu": "81b644d166e0bfb918615af8a2363f8fcf26eccdcc60a5334b6a62c088470bac",
            "x86_64-apple-darwin": "687052a046d33be49dc95dd671816709067cf6176ed36c93ea61b1fe0b883b0f",
            "x86_64-unknown-linux-gnu": "80c3882f14e15cef8260ef5257d198e8f4371ca265887431d939e0d561de3253",
            "x86_64-unknown-linux-musl": "0a461330b9b89f2ea3088dde10d7a3f96aa65897b7c5ce2404fa3b5c4b8daa14",
        },
    },
    "3.13.11": {
        "url": "20251209/cpython-{python_version}+20251209-{platform}-install_only.tar.gz",
        "strip_prefix": "python",
        "sha256": {
            "aarch64-apple-darwin": "295a9f7bc899ea1cc08baf60bbf511bdd1e4a29b2dd7e5f59b48f18bfa6bf585",
            "aarch64-unknown-linux-gnu": "ea1e678e6e82301bb32bf3917732125949b6e46d541504465972024a3f165343",
            "x86_64-apple-darwin": "dac4a0a0a9b71f6b02a8b0886547fa22814474239bffb948e3e77185406ea136",
            "x86_64-unknown-linux-gnu": "1ffa06d714a44aea14c0c54c30656413e5955a6c92074b4b3cb4351dcc28b63b",
            "x86_64-unknown-linux-musl": "969fe24017380b987c4e3ce15e9edf82a4618c1e61672b2cc9b021a1c98eae78",
        },
    },
}

# Mapping from PBS platform triple to Bazel platform constraints.
PLATFORMS = {
    "aarch64-apple-darwin": {
        "compatible_with": [
            "@platforms//os:macos",
            "@platforms//cpu:aarch64",
        ],
        "os_name": "osx",
        "arch": "aarch64",
    },
    "aarch64-unknown-linux-gnu": {
        "compatible_with": [
            "@platforms//os:linux",
            "@platforms//cpu:aarch64",
        ],
        "os_name": "linux",
        "arch": "aarch64",
    },
    "x86_64-apple-darwin": {
        "compatible_with": [
            "@platforms//os:macos",
            "@platforms//cpu:x86_64",
        ],
        "os_name": "osx",
        "arch": "x86_64",
    },
    "x86_64-unknown-linux-gnu": {
        "compatible_with": [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
        "os_name": "linux",
        "arch": "x86_64",
    },
    "x86_64-unknown-linux-musl": {
        "compatible_with": [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
        "os_name": "linux",
        "arch": "x86_64",
    },
}

# Default minor version mapping: "3.11" -> "3.11.14"
# buildifier: disable=unsorted-dict-items
MINOR_MAPPING = {
    "3.11": "3.11.14",
    "3.12": "3.12.12",
    "3.13": "3.13.11",
}
