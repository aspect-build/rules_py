#!/usr/bin/env python3
"""Test that PEP 735 include-group syntax works.

The dev dependency group includes both build and test groups via:
    dev = [
        {include-group = "build"},
        {include-group = "test"},
    ]

This test verifies that packages from both included groups are available.
"""

# From build group
import setuptools
print(f"setuptools: {setuptools.__file__}")

# From test group
import pytest
print(f"pytest: {pytest.__file__}")
