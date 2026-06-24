#!/usr/bin/env python3

"""Test that post-install patches are applied to cowsay."""

import subprocess
import sys
from pathlib import Path

import cowsay
import patched_top_level
import patched_via_pth

# Verify the post-install patch added PATCHED_POST_INSTALL to __init__.py
assert hasattr(cowsay, "PATCHED_POST_INSTALL"), (
    "Post-install patch was not applied: cowsay.PATCHED_POST_INSTALL is missing"
)
assert cowsay.PATCHED_POST_INSTALL is True
print("post_install patch: OK")

# Verify a top-level module added after wheel metadata extraction remains
# importable through the unknown-layout fallback.
assert patched_top_level.PATCHED is True
print("post_install top-level addition: OK")

# Verify the unknown-layout fallback processes root .pth files added by the
# post-install patch.
assert patched_via_pth.PATCHED is True
print("post_install root .pth addition: OK")

# Verify cowsay still works after patching
output = cowsay.get_output_string("cow", "patches work!")
assert "patches work!" in output
print("cowsay functional: OK")

# Console-script metadata remains valid when only package files are patched.
console_script = Path(sys.executable).with_name("cowsay")
subprocess.run([console_script, "--help"], check=True, capture_output=True, text=True)
print("original console script: OK")

print("All patching tests passed.")
