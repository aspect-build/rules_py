"""Verify that `py_binary(external_venv = :v)` forwards `:v`'s env.

Drives the regression test in ../BUILD.bazel — env declared on the
venv target should reach the binary at runtime, and the binary's own
env should override on key conflicts.
"""

import os
import sys


def expect(name, value):
    actual = os.environ.get(name)
    if actual != value:
        print(f"FAIL: {name} = {actual!r}, expected {value!r}", file=sys.stderr)
        sys.exit(1)


# Env from the venv target flows through.
expect("VENV_ONLY", "from_venv")

# Env from the binary target flows through.
expect("BINARY_ONLY", "from_binary")

# On key conflict, the BINARY wins — it's the "inner" scope.
expect("CONFLICTING", "binary_value")

print("OK: external venv env-forwarding works")
