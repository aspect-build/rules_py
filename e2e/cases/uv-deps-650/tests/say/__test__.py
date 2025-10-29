#!/usr/bin/env python3

import cowsay
assert "tests/say/.say/" in cowsay.__file__

import sys
assert sys.version_info.major == 3
assert sys.version_info.minor == 11
