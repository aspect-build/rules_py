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

# The virtualenv changes the sys.prefix, which should be in our runfiles
assert sys.prefix.endswith(".runfiles/aspect_rules_py/py/tests/py-internal-venv/.test")

# That prefix should also be "the" prefix per site.PREFIXES
assert site.PREFIXES[0].endswith(".runfiles/aspect_rules_py/py/tests/py-internal-venv/.test")

# The virtualenv also changes the sys.executable (if we've done this right)
assert sys.executable.find("aspect_rules_py/py/tests/py-internal-venv/.test/bin/python") != -1
