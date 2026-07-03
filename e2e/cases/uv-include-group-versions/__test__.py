#!/usr/bin/env python3
"""Test that version preferences from included dependency groups are preserved.

uv.lock pins colorama to 0.4.6 for the versions-dev group, which includes
versions-build and versions-test. versions-dev also adds a direct
colorama>=0.4.6 constraint, while versions-build references colorama without a
version specifier.

This test verifies that rules_py installs exactly the version uv.lock selected
for versions-dev, not a version that would result from resolving the
unconstrained reference in versions-build.
"""

import colorama
print(f"colorama: {colorama.__file__}")
print(f"colorama version: {colorama.__version__}")
assert colorama.__version__ == "0.4.6", (
    f"Expected colorama ==0.4.6 for versions-dev group, got {colorama.__version__}"
)

import setuptools
print(f"setuptools: {setuptools.__file__}")

import pytest
print(f"pytest: {pytest.__file__}")
