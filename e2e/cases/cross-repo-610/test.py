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

# Cross-repo import test (the core of #610)

# aspect-build/rules_py#610, these imports aren't quite right
import foo
print(foo.__file__)

# Transitive through foo
import bar
print(bar.__file__)
