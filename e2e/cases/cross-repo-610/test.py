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

# The virtualenv changes the sys.prefix, which should be in our runfiles
assert sys.prefix.endswith("/.test")

# That prefix should also be "the" prefix per site.PREFIXES
assert site.PREFIXES[0].endswith("/.test")

# The virtualenv also changes the sys.executable (if we've done this right)
assert sys.executable.find("/.test/bin/python") != -1

# aspect-build/rules_py#610, these imports aren't quite right
import foo
print(foo.__file__)

# Transitive through foo
import bar
print(bar.__file__)
