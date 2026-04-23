"""Verify wheel-declared console scripts are usable via PATH at runtime.

py_binary/py_test generate wrapper scripts under <venv>/bin/<name> from each
wheel's `[console_scripts]` entry points. The launcher prepends <venv>/bin/
to $PATH. This test confirms the whole chain works end-to-end by
subprocess-invoking `cowsay`, which declares a `cowsay` entry point that
calls `cowsay.__main__:cli`.
"""

import os
import shutil
import subprocess
import sys
import unittest


class ConsoleScriptsTest(unittest.TestCase):
    def test_wrapper_is_on_path(self):
        path = shutil.which("cowsay")
        self.assertIsNotNone(
            path,
            "cowsay wrapper not found on PATH (is <venv>/bin/ prepended?)",
        )
        self.assertTrue(
            path.endswith(os.sep + "bin" + os.sep + "cowsay"),
            "expected wrapper under a bin/ directory, got: {!r}".format(path),
        )

    def test_wrapper_invokes_entry_point(self):
        # cowsay 6.1 CLI requires -t <text>; asserts entry-point import and
        # call happens inside the wrapper's Python invocation.
        result = subprocess.run(
            ["cowsay", "-t", "subprocess-invocation-worked"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(
            result.returncode,
            0,
            "cowsay wrapper failed: stdout={!r} stderr={!r}".format(
                result.stdout, result.stderr
            ),
        )
        self.assertIn("subprocess-invocation-worked", result.stdout)


if __name__ == "__main__":
    sys.exit(unittest.main())
