#!/usr/bin/env python3

import sys
print(sys.prefix)

import conflict
print(conflict.__file__)
assert conflict.__file__.startswith(sys.prefix)

import noconflict
print(noconflict.__file__)
assert noconflict.__file__.startswith(sys.prefix)

import py_venv_conflict.lib as srclib
print(srclib.__file__)
assert not srclib.__file__.startswith(sys.prefix)
