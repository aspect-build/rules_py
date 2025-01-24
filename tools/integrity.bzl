"""Release binary integrity hashes.

This file contents are entirely replaced during release publishing.
The checked in content is only here to allow load() statements in the sources to resolve.
"""

# TEST DATA extracted from tools/integrity.bzl file within https://github.com/aspect-build/rules_py/releases/download/v1.2.0/rules_py-v1.2.0.tar.gz
RELEASED_BINARY_INTEGRITY = {
    "unpack-aarch64-apple-darwin": "e973717a34f3bc19a111d2326ca573bd310660851024217e057d276346fc0f6a",
    "unpack-x86_64-apple-darwin": "3ebb392cd01b43804bee638b3e12c19d61a07487367e801bc936bd5fd469fc81",
    "venv-aarch64-apple-darwin": "2f07120fc0a8bbc1ca7ce8b10d5df1b0637c235f66d2f7ad95105ada0792acb1",
    "venv-x86_64-apple-darwin": "134269ced40240e757e2f6705e546d4f905b6e125fec775afe8bd3bfd8aac495",
    "unpack-aarch64-unknown-linux-musl": "0f58e2ae3b29a9884f23eb48ded26b3d5aebf2cedb99461a291c9b4f533d2e64",
    "unpack-x86_64-unknown-linux-musl": "88623e315e885c1eca10574425448a5b3dc1ca5ac34c8b55f0eb8c7f7fa2dd40",
    "venv-aarch64-unknown-linux-musl": "5249e68cc18aaa93bf60c74c927a02d55b7f89722adbc0352d5c144f88ee637e",
    "venv-x86_64-unknown-linux-musl": "ec524c9f9e5cf7f31168a1f74eddd8fa98033ecc229580f69990cd6f65d164dd",
}
