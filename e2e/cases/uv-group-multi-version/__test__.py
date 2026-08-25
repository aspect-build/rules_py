#!/usr/bin/env python3
"""Reproduce multi-version packages within a single dependency group.

The `depctx_py_multiver_uv` group locks `six` at two versions gated by
disjoint `sys_platform` markers, both directly and transitively through
`retrying`. If the group preference resolution collapses the candidates
(last-write-wins), the wrong version is wired for the active platform.
"""

import sys
from importlib.metadata import version

import retrying
import six

expected = "1.16.0" if sys.platform == "linux" else "1.17.0"
actual = version("six")

print(f"sys.platform: {sys.platform}")
print(f"six: {actual} (expected {expected}) at {six.__file__}")
print(f"retrying: {retrying.__file__}")

assert actual == expected, f"six=={actual}, expected {expected} for {sys.platform}"
