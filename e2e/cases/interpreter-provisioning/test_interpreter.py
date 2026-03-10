"""Verify the running interpreter comes from aspect_rules_py provisioning, not rules_python."""

import os
import sys


def test_not_rules_python():
    # In a py_venv_test, sys.executable points to the venv bin/python symlink.
    # Resolve it to find the actual interpreter binary.
    real_exe = os.path.realpath(sys.executable)
    assert "pythons_hub" not in real_exe, (
        "Expected aspect_rules_py interpreter, got rules_python: " + real_exe
    )


if __name__ == "__main__":
    test_not_rules_python()
    real_exe = os.path.realpath(sys.executable)
    print("OK: interpreter is", real_exe)
