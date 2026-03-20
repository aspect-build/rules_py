#!/usr/bin/env python3

"""Test that the venv interpreter works when invoked with -I (isolated mode).

Regression test for https://github.com/aspect-build/rules_py/issues/703.

IDE extensions (e.g. the VS Code Python extension) invoke the interpreter with
`python -I ...` which sets isolated mode. Isolated mode implies -E (ignore
environment variables) and -s (no user site). Since the venv shim relies on
setting PYTHONHOME in the environment, -I/-E causes the interpreter to fail
with "No module named 'encodings'" because it can't find the stdlib.
"""

import os
import subprocess
import sys


def test_python_dash_I():
    """Invoke the venv interpreter with -I and verify it can still start."""
    python = sys.executable
    assert python, "sys.executable is not set"

    # This is what IDE extensions do: python -I <script>
    result = subprocess.run(
        [python, "-I", "-c", "import sys; print(sys.executable)"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"STDOUT: {result.stdout}", file=sys.stderr)
        print(f"STDERR: {result.stderr}", file=sys.stderr)
    assert result.returncode == 0, (
        f"'python -I -c ...' failed with rc={result.returncode}.\n"
        f"stderr: {result.stderr}"
    )
    print(f"python -I: executable = {result.stdout.strip()}")


def test_python_dash_E():
    """Invoke the venv interpreter with -E (ignore environment)."""
    python = sys.executable
    result = subprocess.run(
        [python, "-E", "-c", "import sys; print(sys.prefix)"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"STDOUT: {result.stdout}", file=sys.stderr)
        print(f"STDERR: {result.stderr}", file=sys.stderr)
    assert result.returncode == 0, (
        f"'python -E -c ...' failed with rc={result.returncode}.\n"
        f"stderr: {result.stderr}"
    )
    print(f"python -E: prefix = {result.stdout.strip()}")


def test_python_dash_I_can_import():
    """Verify that -I doesn't break stdlib imports."""
    python = sys.executable
    result = subprocess.run(
        [python, "-I", "-c", "import json; print(json.dumps({'ok': True}))"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"STDOUT: {result.stdout}", file=sys.stderr)
        print(f"STDERR: {result.stderr}", file=sys.stderr)
    assert result.returncode == 0, (
        f"'python -I -c import json' failed with rc={result.returncode}.\n"
        f"stderr: {result.stderr}"
    )
    assert result.stdout.strip() == '{"ok": true}', (
        f"Unexpected output: {result.stdout.strip()!r}"
    )
    print("python -I: stdlib imports work")


if __name__ == "__main__":
    test_python_dash_I()
    test_python_dash_E()
    test_python_dash_I_can_import()
    print("All isolated mode tests passed.")
