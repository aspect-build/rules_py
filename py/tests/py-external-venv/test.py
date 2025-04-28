#!/usr/bin/env python3

import os
import sys
import site

# The virtualenv module should have already been loaded at interpreter startup
assert "_virtualenv" in sys.modules

print(__file__)
print(sys.prefix)
print(sys.executable)
for p in site.PREFIXES:
    print(" -", p)
