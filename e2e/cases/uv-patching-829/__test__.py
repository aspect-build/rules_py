#!/usr/bin/env python3

"""Test that pre-build and post-install patches are applied to cowsay."""

import cowsay

# Verify the post-install patch added PATCHED_POST_INSTALL to __init__.py
assert hasattr(cowsay, "PATCHED_POST_INSTALL"), (
    "Post-install patch was not applied: cowsay.PATCHED_POST_INSTALL is missing"
)
assert cowsay.PATCHED_POST_INSTALL is True
print("post_install patch: OK")

# Verify the pre-build patch added PATCHED_PRE_BUILD to main.py
from cowsay.main import PATCHED_PRE_BUILD
assert PATCHED_PRE_BUILD is True
print("pre_build patch: OK")

# Verify cowsay still works after patching
output = cowsay.get_output_string("cow", "patches work!")
assert "patches work!" in output
print("cowsay functional: OK")

print("All patching tests passed.")
