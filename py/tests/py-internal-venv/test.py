#!/usr/bin/env python3

import os
import sys
import site
import subprocess

print("---")
print("__file__:", __file__)
print("sys.prefix:", sys.prefix)
print("sys.executable:", sys.executable)
print("site.PREFIXES:")
for p in site.PREFIXES:
    print(" -", p)

# The virtualenv module should have already been loaded at interpreter startup
assert "_virtualenv" in sys.modules

# Note that we can't assume that a `.runfiles` tree has been created as CI may
# use a different layout.

# The virtualenv changes sys.prefix to a dot-prefixed directory under
# this test's package — assert on the structural invariant rather
# than the specific basename.
_prefix_parent, _prefix_basename = os.path.split(sys.prefix.rstrip("/"))
assert _prefix_parent.endswith("/py/tests/py-internal-venv"), sys.prefix
assert _prefix_basename.startswith("."), sys.prefix

# That prefix should also be "the" prefix per site.PREFIXES
assert site.PREFIXES[0] == sys.prefix

# The virtualenv also changes the sys.executable (if we've done this right)
assert sys.executable.startswith(sys.prefix + "/bin/python"), sys.executable

if os.name != "nt":
    child_cwd, child_executable, child_base_prefix = subprocess.check_output(
        [
            sys.executable,
            "-c",
            "import cowsay, os, sys; print(os.getcwd()); print(sys.executable); "
            "print(sys.base_prefix)",
        ],
        env={},
        text=True,
    ).splitlines()
    assert child_cwd == os.getcwd(), (child_cwd, os.getcwd())
    assert child_executable == sys.executable, (child_executable, sys.executable)
    assert child_base_prefix != "/install", child_base_prefix
