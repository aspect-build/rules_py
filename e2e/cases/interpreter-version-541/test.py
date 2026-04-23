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

# Assert that we booted against the expected interpreter version

# Assert that we booted against the expected interpreter version
EXPECTED_VERSION = "<VERSION>"
print(repr(EXPECTED_VERSION))
print(repr(sys.version))
assert sys.version.startswith(EXPECTED_VERSION)
