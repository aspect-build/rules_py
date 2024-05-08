"""Release binary integrity hashes.

This file contents are entirely replaced during release publishing.
The checked in content is only here to allow load() statements in the sources to resolve.
"""

# TEST DATA extracted from tools/integrity.bzl file within https://github.com/aspect-build/rules_py/releases/download/v0.7.3/rules_py-v0.7.3.tar.gz
RELEASED_BINARY_INTEGRITY = {
    "unpack-aarch64-apple-darwin": "7b707566f3d47faae3f27715fb1ae1689d3d1003c21b60d344c644fdee54aef9",
    "unpack-x86_64-apple-darwin": "6e10eb9c8a336adf2c091fd0de73a0e6a2e9ff104829a2516f1283b1429deaea",
    "venv-aarch64-apple-darwin": "cda216aed9cb6c6a9d9d5627f5d109139536d94e206e5248b1027bd0fbc42342",
    "venv-x86_64-apple-darwin": "12ea7c3e0a660322059610aac6ce05c93667a17cfa3f3585d442e9e4815edef0",
    "unpack-aarch64-unknown-linux-gnu": "e6da0ffc82b462ec14e6e660c396bc9530d7f1588729e3dd6500508c661e1819",
    "unpack-x86_64-unknown-linux-gnu": "35fc4335877a852a6fa1bd3ac2f99d756376ef8540d1bfa36ac7abf9c4fcc8f8",
    "venv-aarch64-unknown-linux-gnu": "b51756d0d66a0defcc176c2363f649a698e235f56f6d6cbc3bc2142fb99b0240",
    "venv-x86_64-unknown-linux-gnu": "79e753c51d51c37d77151e2c36df52d5f0eb9b301e6001274a92ce9d0cdf67cd",
}
