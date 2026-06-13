"""Regression test: coverage data from Python subprocesses is captured.

The test calls foo.subtract() in a subprocess. If subprocess coverage
propagation works, the LCOV report will include a DA hit for line 5
of foo.py (the subtract function body).
"""

import os
import subprocess
import sys

from examples.pytest.foo import add


def test_add_in_process():
    assert add(1, 1) == 2


def test_subtract_in_subprocess():
    env = {**os.environ, "PYTHONPATH": os.pathsep.join(sys.path)}
    result = subprocess.run(
        [sys.executable, "-c", "from examples.pytest.foo import subtract; print(subtract(3, 1))"],
        capture_output=True,
        text=True,
        env=env,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "2"
