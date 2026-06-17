"""Restore virtualenv process state passed by the native launcher."""

import os
import sys


def initialize() -> None:
    cwd = os.environ.pop("_ASPECT_RULES_PY_VENV_CWD", None)
    argv0 = os.environ.pop("_ASPECT_RULES_PY_VENV_ARGV0", None)
    base_executable = os.environ.pop("_ASPECT_RULES_PY_VENV_BASE_EXECUTABLE", None)
    pythonpath = os.environ.pop("_ASPECT_RULES_PY_VENV_PYTHONPATH", None)
    if base_executable:
        sys._base_executable = base_executable
    if cwd:
        sys.base_prefix = os.path.abspath(sys.base_prefix)
        sys.base_exec_prefix = os.path.abspath(sys.base_exec_prefix)
        os.chdir(cwd)
        sys.executable = os.path.join(sys.prefix, "bin", "python")
    if argv0 is not None:
        sys.argv[0] = argv0
    if pythonpath is not None:
        os.environ["PYTHONPATH"] = pythonpath
