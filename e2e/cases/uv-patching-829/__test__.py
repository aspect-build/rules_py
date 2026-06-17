#!/usr/bin/env python3

"""Test that post-install patches are applied to cowsay."""

import subprocess
import sys
from pathlib import Path

import cowsay

# Verify the post-install patch added PATCHED_POST_INSTALL to __init__.py
assert hasattr(cowsay, "PATCHED_POST_INSTALL"), (
    "Post-install patch was not applied: cowsay.PATCHED_POST_INSTALL is missing"
)
assert cowsay.PATCHED_POST_INSTALL is True
print("post_install patch: OK")

# Verify cowsay still works after patching
output = cowsay.get_output_string("cow", "patches work!")
assert "patches work!" in output
print("cowsay functional: OK")

cowsay_script = Path(sys.prefix) / "bin" / "cowsay"
result = subprocess.run(
    [cowsay_script, "-t", "shared metadata works!"],
    capture_output=True,
    text=True,
)
assert result.returncode == 0, result.stderr
assert "shared metadata works!" in result.stdout

print("All patching tests passed.")
