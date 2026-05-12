"""Regression test: cryptography ships cp311-abi3 wheels that must be
recognized as compatible with Python 3.12 (and any newer 3.x).
If abi3 compatibility isn't propagated, this import will fail because
Bazel falls back to the sdist instead of selecting the prebuilt wheel.

Additionally, cryptography 46.0.5 ships BOTH cp311-abi3 and cp38-abi3
wheels for the same platforms. The cp311 one is more specific for any
Python >= 3.11 and must win the wheel selection for python 3.12. We
verify this by reading the installed dist-info/WHEEL metadata."""

import importlib.metadata

from cryptography import __version__

print(f"cryptography {__version__} imported successfully")

# The WHEEL file records the source wheel's tags (PEP 427). For our
# python_version=3.12 build, the cp311-abi3 wheel must have been
# selected. If the bug regresses, the cp38-abi3 wheel wins and this
# assertion fails.
wheel_meta = importlib.metadata.distribution("cryptography").read_text("WHEEL")
assert wheel_meta is not None, "cryptography dist-info/WHEEL not found"
tags = [
    line.split(":", 1)[1].strip()
    for line in wheel_meta.splitlines()
    if line.startswith("Tag:")
]
assert any(t.startswith("cp311-abi3-") for t in tags), (
    f"expected cp311-abi3 wheel for python 3.12, got tags={tags}"
)
print(f"selected wheel tags: {tags}")
