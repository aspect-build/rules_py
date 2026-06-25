"""Compatible directory claimants and root `.pth` files remain visible."""

import sys

import apkg
import bpkg
import shared

assert apkg.VALUE == "apkg"
assert bpkg.VALUE == "bpkg"
assert shared.OWNER == "merged"
assert "rules_py_itf_sentinel_a" in sys.path
assert "rules_py_itf_sentinel_b" in sys.path
