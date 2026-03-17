"""Regression test: cryptography ships cp311-abi3 wheels that must be
recognized as compatible with Python 3.12 (and any newer 3.x).
If abi3 compatibility isn't propagated, this import will fail because
Bazel falls back to the sdist instead of selecting the prebuilt wheel."""

from cryptography import __version__

print(f"cryptography {__version__} imported successfully")
