from __future__ import annotations

import os
import sys
import unittest
from unittest import mock

import launcher_bootstrap


class LauncherBootstrapTest(unittest.TestCase):
    def test_scans_attached_isolated_module(self) -> None:
        self.assertEqual(
            launcher_bootstrap._scan_args(["-Impytest", "arg"]),
            launcher_bootstrap._ParsedArgs(False, True, None),
        )

    def test_does_not_treat_module_name_as_script(self) -> None:
        self.assertEqual(
            launcher_bootstrap._scan_args(["-P", "-m", "module"]),
            launcher_bootstrap._ParsedArgs(False, False, None),
        )

    def test_absolutizes_venv_before_changing_directory(self) -> None:
        cwd = os.getcwd()
        absolute_pythonpath = os.path.join(cwd, "absolute-pythonpath")
        with (
            mock.patch.object(
                sys,
                "argv",
                [
                    "launcher_bootstrap.py",
                    "runfiles/python/bin/python3",
                    "runfiles/tool.venv/pyvenv.cfg",
                    "-c",
                    "pass",
                ],
            ),
            mock.patch.object(os, "chdir") as chdir,
            mock.patch.object(os, "execve", side_effect=RuntimeError) as execve,
            mock.patch.object(sys, "platform", "darwin"),
            mock.patch.dict(
                os.environ,
                {
                    "_ASPECT_RULES_PY_VENV_ARGV0": "ambient-script.py",
                    "_ASPECT_RULES_PY_VENV_CWD": "/ambient/cwd",
                    "JAVA_RUNFILES": "runfiles",
                    "PYTHONHOME": "/bootstrap-only",
                    "PYTHONPATH": os.pathsep.join(
                        ["relative-pythonpath", absolute_pythonpath]
                    ),
                    "RUNFILES_DIR": "runfiles",
                    "RUNFILES_MANIFEST_FILE": "runfiles/MANIFEST",
                },
            ),
            self.assertRaises(RuntimeError),
        ):
            launcher_bootstrap.main()

        chdir.assert_called_once_with(os.path.join(cwd, "runfiles", "python", "bin"))
        interpreter = os.path.join(cwd, "runfiles", "python", "bin", "python3")
        self.assertEqual(execve.call_args.args[1][0], interpreter)
        child_env = execve.call_args.args[2]
        self.assertEqual(
            child_env["__PYVENV_LAUNCHER__"],
            os.path.join(cwd, "runfiles", "tool.venv", "bin", "python"),
        )
        self.assertEqual(child_env["JAVA_RUNFILES"], os.path.join(cwd, "runfiles"))
        self.assertEqual(child_env["RUNFILES_DIR"], os.path.join(cwd, "runfiles"))
        self.assertEqual(
            child_env["RUNFILES_MANIFEST_FILE"],
            os.path.join(cwd, "runfiles", "MANIFEST"),
        )
        self.assertNotIn("PYTHONHOME", child_env)
        self.assertEqual(
            child_env["_ASPECT_RULES_PY_VENV_BASE_EXECUTABLE"],
            interpreter,
        )
        self.assertEqual(child_env["_ASPECT_RULES_PY_VENV_CWD"], cwd)
        self.assertNotIn("_ASPECT_RULES_PY_VENV_ARGV0", child_env)
        self.assertEqual(
            child_env["PYTHONPATH"],
            os.pathsep.join(
                [os.path.join(cwd, "relative-pythonpath"), absolute_pythonpath]
            ),
        )
        self.assertEqual(
            child_env["_ASPECT_RULES_PY_VENV_PYTHONPATH"],
            os.pathsep.join(["relative-pythonpath", absolute_pythonpath]),
        )

    def test_uses_pbs_identity_when_site_and_environment_are_disabled(self) -> None:
        interpreter = os.path.realpath(sys.executable)
        with (
            mock.patch.object(
                sys,
                "argv",
                [
                    "launcher_bootstrap.py",
                    interpreter,
                    "runfiles/tool.venv/pyvenv.cfg",
                    "-I",
                    "-S",
                    "-c",
                    "pass",
                ],
            ),
            mock.patch.object(os, "chdir") as chdir,
            mock.patch.object(os, "execve", side_effect=RuntimeError) as execve,
            self.assertRaises(RuntimeError),
        ):
            launcher_bootstrap.main()

        chdir.assert_not_called()
        self.assertEqual(execve.call_args.args[1][0], interpreter)
        self.assertNotIn(
            "_ASPECT_RULES_PY_VENV_BASE_EXECUTABLE", execve.call_args.args[2]
        )
        self.assertNotIn("PYTHONHOME", execve.call_args.args[2])

    def test_python_3_14_resolves_relative_home_from_interpreter_dir(self) -> None:
        cwd = os.getcwd()
        with (
            mock.patch.object(
                sys,
                "argv",
                [
                    "launcher_bootstrap.py",
                    "runfiles/python/bin/python3",
                    "runfiles/tool.venv/pyvenv.cfg",
                    "-I",
                    "-c",
                    "pass",
                ],
            ),
            mock.patch.object(sys, "version_info", (3, 14)),
            mock.patch.object(sys, "platform", "linux"),
            mock.patch.object(os, "chdir") as chdir,
            mock.patch.object(os, "execve", side_effect=RuntimeError) as execve,
            mock.patch.dict(
                os.environ,
                {
                    "_ASPECT_RULES_PY_VENV_CWD": "/ambient/cwd",
                    "PYTHONHOME": "/ambient/home",
                },
                clear=True,
            ),
            self.assertRaises(RuntimeError),
        ):
            launcher_bootstrap.main()

        chdir.assert_called_once_with(
            os.path.join(cwd, "runfiles", "python", "bin")
        )
        self.assertEqual(
            execve.call_args.args[1],
            [
                os.path.join(cwd, "runfiles", "tool.venv", "bin", "python"),
                "-I",
                "-c",
                "pass",
            ],
        )
        self.assertEqual(execve.call_args.args[2]["_ASPECT_RULES_PY_VENV_CWD"], cwd)
        self.assertIn("_ASPECT_RULES_PY_VENV_BASE_EXECUTABLE", execve.call_args.args[2])
        self.assertNotIn("PYTHONHOME", execve.call_args.args[2])

    def test_preserves_empty_pythonpath(self) -> None:
        with (
            mock.patch.object(
                sys,
                "argv",
                [
                    "launcher_bootstrap.py",
                    sys.executable,
                    "runfiles/tool.venv/pyvenv.cfg",
                    "-P",
                    "-c",
                    "pass",
                ],
            ),
            mock.patch.object(os, "chdir"),
            mock.patch.object(os, "execve", side_effect=RuntimeError) as execve,
            mock.patch.dict(os.environ, {"PYTHONPATH": ""}, clear=True),
            self.assertRaises(RuntimeError),
        ):
            launcher_bootstrap.main()

        self.assertEqual(execve.call_args.args[2]["PYTHONPATH"], "")


if __name__ == "__main__":
    unittest.main()
