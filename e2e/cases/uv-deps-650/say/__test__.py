#!/usr/bin/env python3

import cowsay
print(cowsay.__file__)
assert "cases/uv-deps-650/third_party/cowsay" in cowsay.__file__

cowsay.servitor("Hello, world!")

import sys
assert sys.version_info.major == 3
assert sys.version_info.minor == 11
