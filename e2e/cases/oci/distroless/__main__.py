#!/usr/bin/env python3
"""Distroless container smoke test for py_venv_binary with hermetic launcher."""

import os
import sys

errors = []


def check(name, condition, msg):
    if not condition:
        errors.append(f"FAIL: {name}: {msg}")
    else:
        print(f"  OK: {name}")


print("Hello from distroless!")
print(f"Python {sys.version}")
print(f"sys.executable = {sys.executable}")
print(f"sys.prefix = {sys.prefix}")

# Verify no double slashes in paths (#538)
check("__file__ no //", "//" not in __file__, f"__file__={__file__}")
check("sys.executable no //", "//" not in sys.executable,
      f"sys.executable={sys.executable}")

# Verify VIRTUAL_ENV is set (venv_shim should set it)
venv = os.environ.get("VIRTUAL_ENV", "")
check("VIRTUAL_ENV set", bool(venv), "VIRTUAL_ENV is not set")
check("VIRTUAL_ENV no //", "//" not in venv, f"VIRTUAL_ENV={venv}")

# Verify BAZEL_TARGET is set (RunEnvironmentInfo)
check("BAZEL_TARGET set", "BAZEL_TARGET" in os.environ,
      "BAZEL_TARGET not in environment")

if errors:
    print()
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
