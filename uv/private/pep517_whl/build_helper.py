#!/usr/bin/env python3

"""
A minimal python3 -m build wrapper

Mostly exists to allow debugging.
"""

from argparse import ArgumentParser
import json
import os
import platform as _platform
import shlex
import shutil
import sys
from os import chmod, defpath, listdir, makedirs, path, pathsep
from subprocess import CalledProcessError, check_call, check_output, STDOUT, run
from tempfile import TemporaryFile

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib

_SETUPTOOLS_BACKENDS = (
    None,
    "setuptools.build_meta",
    "setuptools.build_meta:__legacy__",
)


# Configured tools may be relative to Bazel's execroot, while build backends
# run from the unpacked source tree. Resolve every executable before that cwd
# change; default compiler wrappers embed the resulting absolute paths.
_DEBUG_FLAG = "-fdebug-default-version=4"
_COMPILER_WRAPPER = """#!/usr/bin/env python3
import os
import sys

compiler = {compiler!r}
driver_args = {driver_args!r}
filtered_args = [
    arg for arg in driver_args + sys.argv[1:] if arg != {debug_flag!r}
]
sysroot = {sysroot!r}
has_sysroot = any(
    arg in ("-isysroot", "--sysroot")
    or arg.startswith("-isysroot")
    or arg.startswith("--sysroot=")
    for arg in filtered_args
)
if sysroot and not has_sysroot:
    filtered_args = ["-isysroot", sysroot] + filtered_args
os.execv(compiler, [compiler] + filtered_args)
"""
_ERROR_WRAPPER = """#!/usr/bin/env python3
import sys

sys.stderr.write({error!r} + "\\n")
sys.exit(1)
"""

_DEFAULT_COMPILERS = {
    "CC": "cc",
    "CXX": "c++",
}


def _darwin_sysroot():
    """Return the macOS SDK path, or None if unavailable."""
    if _platform.system() != "Darwin":
        return None
    try:
        return check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    except Exception:
        return None


def _resolve_command(env, key, default_command, action_root):
    """Select and absolutize an explicit or toolchain-provided command."""
    current = env.get(key)
    command = shlex.split(current) if current else list(default_command)
    if not command:
        raise ValueError("{} command is empty".format(key))

    executable = command[0]
    if not path.isabs(executable):
        if path.dirname(executable):
            command[0] = path.join(action_root, executable)
        else:
            resolved = shutil.which(executable, path=env["PATH"])
            if resolved is None:
                raise FileNotFoundError(
                    "{} executable not found on PATH: {}".format(key, executable),
                )
            if not path.isabs(resolved):
                resolved = path.join(action_root, resolved)
            command[0] = resolved
    return command


def _visible_compiler_command(command, sysroot):
    command = [argument for argument in command if argument != _DEBUG_FLAG]
    has_sysroot = any(
        argument in ("-isysroot", "--sysroot")
        or argument.startswith("-isysroot")
        or argument.startswith("--sysroot=")
        for argument in command[1:]
    )
    if sysroot and not has_sysroot:
        command[1:1] = ["-isysroot", sysroot]
    return shlex.join(command)


def _compiler_wrapper_source(command, sysroot):
    return _COMPILER_WRAPPER.format(
        compiler=command[0],
        debug_flag=_DEBUG_FLAG,
        driver_args=command[1:],
        sysroot=sysroot,
    )


def _write_tool_wrapper(tmpdir, name, source):
    wrapper_dir = path.join(tmpdir, ".aspect_rules_py_compilers")
    wrapper = path.join(wrapper_dir, name)
    makedirs(path.dirname(wrapper), exist_ok=True)
    with open(wrapper, "w") as f:
        f.write(source)
    chmod(wrapper, 0o755)
    return wrapper


def _native_tool_env(tmpdir, native_tool_config, action_root):
    env = dict(os.environ)
    env["PATH"] = pathsep.join([
        path.dirname(sys.executable),
        env.get("PATH", defpath),
    ])
    env["TMP"] = tmpdir
    env["TEMP"] = tmpdir
    env["TEMPDIR"] = tmpdir

    sysroot = _darwin_sysroot()
    for key, name in [
        ("CC", "cc"),
        ("CXX", "c++"),
    ]:
        explicit = bool(env.get(key))
        configured = native_tool_config.get(key, [_DEFAULT_COMPILERS[key]])
        if isinstance(configured, dict) and not explicit:
            env[key] = _write_tool_wrapper(
                tmpdir,
                name,
                _ERROR_WRAPPER.format(error=configured["error"]),
            )
            continue
        default_command = (
            [_DEFAULT_COMPILERS[key]] if isinstance(configured, dict) else configured
        )
        command = _resolve_command(
            env,
            key,
            default_command,
            action_root,
        )
        if explicit:
            env[key] = _visible_compiler_command(command, sysroot)
        else:
            env[key] = _write_tool_wrapper(
                tmpdir,
                name,
                _compiler_wrapper_source(command, sysroot),
            )

    for key in ("AR", "LD", "STRIP", "CPP", "LDSHARED", "LDCXXSHARED"):
        default_command = native_tool_config.get(key, [])
        if not env.get(key) and not default_command:
            continue
        command = _resolve_command(
            env,
            key,
            default_command,
            action_root,
        )
        env[key] = (
            _visible_compiler_command(command, sysroot)
            if key in ("CPP", "LDSHARED", "LDCXXSHARED")
            else shlex.join(command)
        )

    if env.get("MPICC"):
        command = _resolve_command(env, "MPICC", [], action_root)
        env["MPICC"] = _visible_compiler_command(command, sysroot)
    else:
        mpicc = shutil.which("mpicc", path=env["PATH"])
        if mpicc:
            env["MPICC"] = _write_tool_wrapper(
                tmpdir,
                "mpicc",
                _compiler_wrapper_source([mpicc], sysroot),
            )
    return env


def _load_text(maybe_file):
    if not path.exists(maybe_file):
        return ""

    with open(maybe_file, encoding="utf-8", errors="ignore") as f:
        return f.read()


def _load_pyproject_data(worktree):
    pyproject = path.join(worktree, "pyproject.toml")
    if not path.exists(pyproject):
        return None

    try:
        with open(pyproject, "rb") as f:
            return tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError):
        return None


def _legacy_metadata_conflicts_with_pyproject(worktree):
    setup_py = path.join(worktree, "setup.py")
    pyproject_data = _load_pyproject_data(worktree)
    if not (pyproject_data and path.exists(setup_py)):
        return False

    build_backend = pyproject_data.get("build-system", {}).get("build-backend")
    if build_backend not in _SETUPTOOLS_BACKENDS:
        return False

    project = pyproject_data.get("project")
    if not project:
        return False

    dynamic = set(project.get("dynamic", []))
    legacy_metadata = _load_text(setup_py) + "\n" + _load_text(path.join(worktree, "setup.cfg"))

    return (
        ("dependencies" not in project and "dependencies" not in dynamic and "install_requires" in legacy_metadata) or
        (
            "optional-dependencies" not in project and
            "optional-dependencies" not in dynamic and
            "extras_require" in legacy_metadata
        )
    )

PARSER = ArgumentParser()
PARSER.add_argument("srcarchive")
PARSER.add_argument("outdir")
PARSER.add_argument("--native-tool-config")
PARSER.add_argument("--validate-anyarch", action="store_true")
PARSER.add_argument("--patch-strip", type=int, default=0, help="Strip count for patch (-p)")
PARSER.add_argument("--patch", action="append", default=[], dest="patches", help="Patch file to apply (repeatable)")
opts, args = PARSER.parse_known_args()

action_root = path.abspath(os.curdir)
native_tool_config = json.loads(opts.native_tool_config) if opts.native_tool_config else {}
tmp_root = path.abspath(opts.outdir) + ".tmp"
# Sandboxed/remote actions get a fresh root each run, so we don't expect a stale tmp_root to exist.
makedirs(tmp_root, exist_ok=False)

t = path.join(tmp_root, "worktree")

shutil.unpack_archive(opts.srcarchive, t)

# Annoyingly, unpack_archive creates a subdir in the target. Update t
# accordingly. Not worth the eng effort to prevent creating this dir.
t = path.join(t, listdir(t)[0])

if opts.patches:
    for patch_file in opts.patches:
        abs_patch = path.abspath(patch_file)
        # --no-backup-if-mismatch: a fuzz/offset apply otherwise drops a
        # `<file>.orig` into the worktree that gets swept into the built wheel.
        patch_cmd = [
            "patch",
            "--no-backup-if-mismatch",
            "-p{}".format(opts.patch_strip),
            "-i",
            abs_patch,
        ]
        try:
            check_call(patch_cmd, cwd=t)
        except CalledProcessError as exc:
            # Fail with a concise reason on stderr instead of a Python traceback.
            print(
                "Error: failed to apply patch {} (patch exited {}).".format(abs_patch, exc.returncode),
                file=sys.stderr,
            )
            exit(1)


# Get a path to the outdir which will be valid after we cd
outdir = path.abspath(opts.outdir)

# Preserve configured compiler and linker commands through the cwd change into
# the worktree.
build_env = _native_tool_env(tmp_root, native_tool_config, action_root)

if _legacy_metadata_conflicts_with_pyproject(t):
    print(
        "Warning: falling back to setup.py because pyproject.toml omits dynamic dependency metadata "
        "that setuptools still reads from setup.py/setup.cfg.",
        file=sys.stderr,
    )
    cmd = [
        sys.executable,
        path.realpath(path.join(t, "setup.py")),
        "bdist_wheel",
        "--dist-dir",
        outdir,
    ]
elif path.exists(path.join(t, "pyproject.toml")) or path.exists(path.join(t, "setup.py")):
    # Always use `python -m build` (PEP 517 frontend). For setup.py-only
    # packages without a pyproject.toml, build creates a minimal PEP 517
    # shim automatically. --no-isolation ensures it uses the deps we've
    # already provided in the build venv rather than trying to pip-install.
    # Routing legacy setup_requires=… packages (e.g. googlemaps 4.10.0)
    # through setup.py directly triggers setuptools' deprecated
    # fetch_build_eggs path, which crashes on modern packaging.
    #
    # --skip-dependency-check disables `build`'s validation of
    # `[build-system].requires` against the active venv. The
    # validation is redundant under --no-isolation (we already
    # commit to managing the venv) and rejects packages that pile
    # unrelated dev tooling into `requires` — cdifflib 1.2.9 lists
    # pytest/ruff/twine there, none of which are actually needed
    # to compile its C extension.
    cmd = [
        sys.executable,
        "-m", "build",
        "--wheel",
        "--no-isolation",
        "--skip-dependency-check",
        "--outdir", outdir,
    ]
else:
    print("Error: Unable to detect build command! Neither pyproject.toml nor setup.py found!", file=sys.stderr)
    exit(1)

with TemporaryFile(mode="w+") as build_log:
    try:
        run(cmd, cwd=t, env=build_env, stdout=build_log, stderr=STDOUT, check=True)
    except CalledProcessError:
        build_log.seek(0)
        output = build_log.read()
        if output:
            sys.stderr.write(output)
            if not output.endswith("\n"):
                sys.stderr.write("\n")
        print("Error: Build failed!\nSee {} for the sandbox".format(t), file=sys.stderr)
        exit(1)

inventory = listdir(outdir)

if len(inventory) > 1:
    print("Error: Built more than one wheel!\nSee {} for the sandbox".format(t), file=sys.stderr)
    exit(1)

if opts.validate_anyarch and not inventory[0].endswith("-none-any.whl"):
    print("Error: Target was anyarch but built a none-any wheel!\nSee {} for the sandbox".format(t), file=sys.stderr)
    exit(1)
