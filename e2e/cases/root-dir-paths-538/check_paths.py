"""Verify that __file__ and sys.executable don't contain double slashes.

Regression test for https://github.com/aspect-build/rules_py/issues/538
"""

import os
import sys


def test_no_double_slashes():
    assert "//" not in __file__, f"__file__ contains '//': {__file__}"
    assert "//" not in sys.executable, f"sys.executable contains '//': {sys.executable}"
    venv = os.environ.get("VIRTUAL_ENV", "")
    assert "//" not in venv, f"VIRTUAL_ENV contains '//': {venv}"


if __name__ == "__main__":
    test_no_double_slashes()
    print("OK")
