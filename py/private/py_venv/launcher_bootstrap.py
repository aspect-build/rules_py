"""Start a PBS interpreter with virtualenv identity from any location."""

from __future__ import annotations

import os
import sys
from typing import NamedTuple


class _ParsedArgs(NamedTuple):
    site_disabled: bool
    environment_ignored: bool
    script_index: int | None


def _scan_args(args: list[str]) -> _ParsedArgs:
    # Match CPython's clustered short-option parsing and value consumption:
    # https://github.com/python/cpython/blob/v3.12.12/Python/getopt.c
    site_disabled = False
    environment_ignored = False
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in ("-c", "-", "-m"):
            return _ParsedArgs(site_disabled, environment_ignored, None)
        if arg == "--check-hash-based-pycs":
            index += 2
            continue
        if arg == "--":
            script_index = index + 1
            return _ParsedArgs(
                site_disabled,
                environment_ignored,
                script_index if script_index < len(args) else None,
            )
        if arg.startswith("--"):
            index += 1
            continue
        if arg.startswith("-") and arg != "-":
            option_chars = arg[1:]
            for option_index, option in enumerate(option_chars):
                if option == "S":
                    site_disabled = True
                elif option in ("E", "I"):
                    environment_ignored = True
                if option in ("c", "m"):
                    return _ParsedArgs(site_disabled, environment_ignored, None)
                if option in ("W", "X"):
                    index += 1 if option_index + 1 < len(option_chars) else 2
                    break
            else:
                index += 1
            continue
        return _ParsedArgs(site_disabled, environment_ignored, index)
    return _ParsedArgs(site_disabled, environment_ignored, None)


def main() -> None:
    interpreter, pyvenv_cfg, *args = sys.argv[1:]
    interpreter = os.path.realpath(interpreter)
    # Hermetic launchers may return runfile paths relative to the caller's cwd.
    # Preserve the venv location before entering the PBS interpreter directory.
    pyvenv_cfg = os.path.abspath(pyvenv_cfg)
    original_cwd = os.getcwd()

    env = dict(os.environ)
    for name in (
        "_ASPECT_RULES_PY_VENV_ARGV0",
        "_ASPECT_RULES_PY_VENV_BASE_EXECUTABLE",
        "_ASPECT_RULES_PY_VENV_CWD",
        "_ASPECT_RULES_PY_VENV_PYTHONPATH",
        "PYTHONEXECUTABLE",
        "__PYVENV_LAUNCHER__",
    ):
        env.pop(name, None)
    for name in ("RUNFILES_DIR", "RUNFILES_MANIFEST_FILE", "JAVA_RUNFILES"):
        if value := env.get(name):
            env[name] = os.path.abspath(value)
    # PYTHONHOME overrides pyvenv.cfg, so it cannot preserve the venv identity
    # this launcher owns.
    env.pop("PYTHONHOME", None)
    venv_root = os.path.dirname(pyvenv_cfg)
    venv_python = os.path.join(venv_root, "bin", "python")
    parsed = _scan_args(args)
    if not parsed.site_disabled:
        env["_ASPECT_RULES_PY_VENV_BASE_EXECUTABLE"] = interpreter
    argv0 = venv_python
    if parsed.site_disabled:
        if parsed.environment_ignored:
            # Without site or environment variables, CPython cannot retain the
            # venv executable identity. Use the resolved PBS executable so its
            # relocatable standard library remains available.
            argv0 = interpreter
        else:
            env["PYTHONHOME"] = sys.base_prefix
    else:
        env["_ASPECT_RULES_PY_VENV_CWD"] = original_cwd
        if sys.platform == "darwin":
            # CPython's macOS path initialization reserves this variable for
            # launchers that execute the real interpreter while exposing a
            # different virtualenv executable:
            # https://github.com/python/cpython/blob/v3.11.15/Modules/getpath.py#L114-L117
            # https://github.com/python/cpython/blob/v3.11.15/Modules/getpath.py#L312-L327
            env["__PYVENV_LAUNCHER__"] = venv_python
            argv0 = interpreter
        # CPython resolves relative PYTHONPATH entries from its startup cwd:
        # https://docs.python.org/3/using/cmdline.html#envvar-PYTHONPATH
        # Preserve their caller-relative meaning before entering the PBS bin
        # directory for pyvenv.cfg initialization.
        if not parsed.environment_ignored and env.get("PYTHONPATH"):
            env["_ASPECT_RULES_PY_VENV_PYTHONPATH"] = env["PYTHONPATH"]
            env["PYTHONPATH"] = os.pathsep.join(
                os.path.abspath(path) for path in env["PYTHONPATH"].split(os.pathsep)
            )
        if parsed.script_index is not None and not os.path.isabs(
            args[parsed.script_index]
        ):
            env["_ASPECT_RULES_PY_VENV_ARGV0"] = args[parsed.script_index]
            args[parsed.script_index] = os.path.join(
                original_cwd, args[parsed.script_index]
            )
        os.chdir(os.path.dirname(interpreter))

    os.execve(interpreter, [argv0, *args], env)


if __name__ == "__main__":
    main()
