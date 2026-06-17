from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import venv_startup


class VenvStartupTest(unittest.TestCase):
    def test_initialize_restores_launcher_state(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = Path(tempdir)
            venv = root / "venv"
            caller = root / "caller"
            expected_base_prefix = os.path.abspath("relative-base")
            expected_base_exec_prefix = os.path.abspath("relative-exec-base")
            with (
                mock.patch.object(sys, "prefix", str(venv)),
                mock.patch.object(sys, "base_prefix", "relative-base"),
                mock.patch.object(sys, "base_exec_prefix", "relative-exec-base"),
                mock.patch.object(sys, "_base_executable", "../bin/python"),
                mock.patch.object(sys, "executable", "/bootstrap/python"),
                mock.patch.object(sys, "argv", ["/absolute/script.py"]),
                mock.patch.object(
                    sys,
                    "path",
                    [str(caller / "relative-pythonpath"), "/stdlib"],
                ),
                mock.patch.object(os, "chdir") as chdir,
                mock.patch.dict(
                    os.environ,
                    {
                        "_ASPECT_RULES_PY_VENV_ARGV0": "script.py",
                        "_ASPECT_RULES_PY_VENV_BASE_EXECUTABLE": "/pbs/bin/python",
                        "_ASPECT_RULES_PY_VENV_CWD": str(caller),
                        "_ASPECT_RULES_PY_VENV_PYTHONPATH": "relative-pythonpath",
                        "PYTHONPATH": str(caller / "relative-pythonpath"),
                    },
                    clear=True,
                ),
            ):
                venv_startup.initialize()

                chdir.assert_called_once_with(str(caller))
                self.assertEqual(sys.base_prefix, expected_base_prefix)
                self.assertEqual(sys.base_exec_prefix, expected_base_exec_prefix)
                self.assertEqual(sys._base_executable, "/pbs/bin/python")
                self.assertEqual(sys.executable, str(venv / "bin/python"))
                self.assertEqual(
                    sys.path, [str(caller / "relative-pythonpath"), "/stdlib"]
                )
                self.assertEqual(sys.argv[0], "script.py")
                self.assertEqual(os.environ["PYTHONPATH"], "relative-pythonpath")
                self.assertFalse(
                    any(
                        name.startswith("_ASPECT_RULES_PY_VENV_") for name in os.environ
                    )
                )


if __name__ == "__main__":
    unittest.main()
