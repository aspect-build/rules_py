#!/usr/bin/env python3

import os
import sys
import site

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
# this test's package — the exact basename varies by rule variant
# (py_test uses `.<name>_venv/`, py_venv_test uses `.<name>/`), so
# assert on the structural invariant rather than the specific name.
_prefix_parent, _prefix_basename = os.path.split(sys.prefix.rstrip("/"))
assert _prefix_parent.endswith("/py/tests/py-internal-venv"), sys.prefix
assert _prefix_basename.startswith("."), sys.prefix

# That prefix should also be "the" prefix per site.PREFIXES
assert site.PREFIXES[0] == sys.prefix

# The virtualenv also changes the sys.executable (if we've done this right)
assert sys.executable.startswith(sys.prefix + "/bin/python"), sys.executable
