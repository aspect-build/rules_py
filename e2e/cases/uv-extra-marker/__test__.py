#!/usr/bin/env python3
"""Reproduce omitted extra-only markers.

The dev dependency group activates the project's `build` extra, which should
make `colorama` available. If rules_py evaluates `extra == 'build'` to false
because the active venv is named `dev`, the dependency is dropped and this
import fails.
"""

import colorama

print(f"colorama: {colorama.__file__}")
