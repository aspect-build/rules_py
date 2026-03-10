"""Verify the running interpreter comes from aspect_rules_py provisioning, not rules_python."""

import sys


def test_not_rules_python():
    exe = sys.executable
    assert "pythons_hub" not in exe, (
        "Expected aspect_rules_py interpreter, got rules_python: " + exe
    )
    assert "rules_python" not in exe, (
        "Expected aspect_rules_py interpreter, got rules_python: " + exe
    )


def test_is_aspect_interpreter():
    exe = sys.executable
    assert "python_3_" in exe, (
        "Expected interpreter repo name matching python_3_*, got: " + exe
    )


if __name__ == "__main__":
    test_not_rules_python()
    test_is_aspect_interpreter()
    print("OK: interpreter is", sys.executable)
