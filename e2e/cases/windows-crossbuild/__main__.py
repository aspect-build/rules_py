"""Trivial entrypoint for Windows cross-build test.

This script is never executed — the test only verifies that the venv
is assembled correctly with Windows interpreter and native extensions.
"""

import win32api  # noqa: F401

print("Hello from Windows!")
