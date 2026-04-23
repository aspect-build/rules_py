#!/usr/bin/env python3

import sys
import site

print("---")
print("__file__:", __file__)
print("sys.prefix:", sys.prefix)
print("sys.executable:", sys.executable)
print("site.PREFIXES:")
for p in site.PREFIXES:
    print(" -", p)

# Historically this test also asserted `_virtualenv in sys.modules` — that
# module is written into site-packages by the Rust venv_tool (still used by
# py_venv_test) to patch distutils. The new py_binary/py_test path builds
# its venv via ctx.actions.symlink at analysis time and has no pip/distutils
# interactions at runtime, so the shim isn't needed or emitted. The primary
# purpose of this test is the version check below.

# Assert that we booted against the expected interpreter version
EXPECTED_VERSION = "<VERSION>"
print(repr(EXPECTED_VERSION))
print(repr(sys.version))
assert sys.version.startswith(EXPECTED_VERSION)
