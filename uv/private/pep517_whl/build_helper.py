#!/usr/bin/env python3

"""
A minimal python3 -m build wrapper

Mostly exists to allow debugging.
"""

from __future__ import annotations

from argparse import ArgumentParser
import importlib
import os
import platform as _platform
import shlex
import shutil
import sys
from os import chmod, defpath, listdir, makedirs, path, pathsep
from subprocess import CalledProcessError, check_call, check_output, STDOUT, run
from tempfile import TemporaryFile
from typing import Dict, Optional

try:
    tomllib = importlib.import_module("tomllib")
except ModuleNotFoundError:
    tomllib = importlib.import_module("tomli")

_SETUPTOOLS_BACKENDS = (
    None,
    "setuptools.build_meta",
    "setuptools.build_meta:__legacy__",
)


# pep517_native_whl supplies compiler execpaths relative to the action
# execroot, which do not resolve from the backend's unpacked worktree. Point
# CC / CXX / CPP / LDSHARED / LDCXXSHARED at absolute wrappers under tmp_root;
# they strip `-fdebug-default-version=4` and exec the resolved compiler.
_DEBUG_FLAG = "-fdebug-default-version=4"
_COMPILER_WRAPPER = """#!/usr/bin/env python3
import os
import sys

filtered_args = [arg for arg in sys.argv[1:] if arg != "{debug_flag}"]
sysroot = {sysroot!r}
if sysroot and "-isysroot" not in filtered_args:
    filtered_args = ["-isysroot", sysroot] + filtered_args
os.execv("{compiler_path}", [os.path.basename("{compiler_path}")] + filtered_args)
"""


def _darwin_sysroot() -> Optional[str]:
    """Return the macOS SDK path, or None if unavailable."""
    if _platform.system() != "Darwin":
        return None
    try:
        return check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    except Exception:
        return None


def _absolutize_path(value: str) -> str:
    """Resolve a relative path to absolute, leaving absolute/empty values untouched.

    Shared by _resolve_compiler_path (CC/CXX) and _absolutize_tool_paths.
    Toolchain execroot-relative paths break once the PEP 517 backend chdirs into the
    unpacked sdist. Centralizing the policy keeps the two paths in lockstep
    and gives future toolchains (FC, RUSTC, ...) a single primitive to call.
    """
    return path.abspath(value) if value and not path.isabs(value) else value


def _resolve_compiler_path(env: Dict[str, str], key: str, default: str) -> str:
    """Extract the real compiler from the environment and resolve it to an absolute path."""
    current = env.get(key)
    if not current:
        return default
    parts = shlex.split(current)
    if not parts:
        return default
    compiler = parts[0]
    if path.dirname(compiler):
        return _absolutize_path(compiler)
    return shutil.which(compiler, path=env.get("PATH", defpath)) or compiler


def _local_cxx_companion(compiler_path: str) -> str:
    """Select an executable same-directory C++ peer for a direct local C driver."""
    if not path.isabs(compiler_path):
        return compiler_path

    basename = path.basename(compiler_path)
    executable_suffix = ".exe" if basename.endswith(".exe") else ""
    if executable_suffix:
        basename = basename[:-len(executable_suffix)]
    stem, separator, suffix = basename.rpartition("-")
    if not separator or not suffix.isdigit():
        stem, suffix = basename, ""
    else:
        suffix = "-" + suffix
    for cc_basename, cxx_basename in (("clang", "clang++"), ("gcc", "g++"), ("cc", "c++")):
        if stem != cc_basename and not stem.endswith("-" + cc_basename):
            continue
        companion = path.join(path.dirname(compiler_path), stem[:-len(cc_basename)] + cxx_basename + suffix + executable_suffix)
        if path.isfile(companion) and os.access(companion, os.X_OK):
            return companion
        break
    return compiler_path


def _make_compiler_wrapper(
    tmpdir: str,
    name: str,
    compiler_path: str,
    sysroot: Optional[str] = None,
) -> str:
    wrapper = path.join(tmpdir, ".aspect_rules_py_compilers", name)
    makedirs(path.dirname(wrapper), exist_ok=True)
    with open(wrapper, "w") as f:
        f.write(_COMPILER_WRAPPER.format(
            debug_flag=_DEBUG_FLAG,
            compiler_path=compiler_path,
            sysroot=sysroot,
        ))
    chmod(wrapper, 0o755)
    return wrapper


def _override_tool(env: Dict[str, str], key: str, wrapper: str) -> None:
    current = env.get(key)
    if not current:
        return
    parts = shlex.split(current)
    if parts:
        parts[0] = wrapper
        env[key] = shlex.join(parts)


def _absolutize_tool_paths(env: Dict[str, str]) -> None:
    """Resolve toolchain paths before the backend changes cwd."""
    for key in ("JAVA_HOME", "JAVA"):
        value = env.get(key)
        if value:
            env[key] = _absolutize_path(value)

    for key in ("AR", "LD", "STRIP"):
        value = env.get(key)
        if not value:
            continue
        parts = shlex.split(value)
        if parts and path.dirname(parts[0]):
            parts[0] = _absolutize_path(parts[0])
            env[key] = shlex.join(parts)


def _compiler_env(tmpdir: str, execroot_marker: Optional[str] = None) -> Dict[str, str]:
    env = dict(os.environ)
    if execroot_marker:
        execroot = os.getcwd()
        env = {key: value.replace(execroot_marker, execroot) for key, value in env.items()}
    # The helper's launcher exports RUNFILES_DIR, RUNFILES_MANIFEST_FILE, and
    # JAVA_RUNFILES:
    # https://github.com/hermeticbuild/hermetic-launcher/blob/381814d0818af0573263323dc0dd0e4e208fc3fa/README.md#runfiles-discovery
    # Bazel adds RUNFILES_MANIFEST_ONLY when runfiles trees are disabled:
    # https://github.com/bazelbuild/bazel/blob/9.1.1/src/main/java/com/google/devtools/build/lib/bazel/rules/BazelRuleClassProvider.java#L192-L201
    # Nested Bazel executables check that inherited state before adjacent
    # runfiles, so remove the parent's identity before package code runs.
    for key in (
        "JAVA_RUNFILES",
        "RUNFILES_DIR",
        "RUNFILES_MANIFEST_FILE",
        "RUNFILES_MANIFEST_ONLY",
    ):
        env.pop(key, None)
    env["PATH"] = pathsep.join([
        path.dirname(sys.executable),
        env.get("PATH", defpath),
    ])
    env["TMP"] = tmpdir
    env["TEMP"] = tmpdir
    env["TEMPDIR"] = tmpdir

    # Bazel expands tool paths relative to the execroot. Resolve them while the
    # helper still runs there; bare tool names deliberately remain on PATH.
    _absolutize_tool_paths(env)

    cc_path = _resolve_compiler_path(env, "CC", "cc")
    cxx_path = _resolve_compiler_path(env, "CXX", "c++")
    if env.pop("ASPECT_RULES_PY_INFER_CXX_COMPANION", None) == "1":
        cxx_path = _local_cxx_companion(cxx_path)

    sysroot = _darwin_sysroot()

    cc = _make_compiler_wrapper(tmpdir, "cc", cc_path, sysroot)
    cxx = _make_compiler_wrapper(tmpdir, "c++", cxx_path, sysroot)

    env.setdefault("CC", cc)
    env.setdefault("CXX", cxx)

    # MPI builds (e.g. mpi4py) consult $MPICC before searching PATH, so a
    # plain C compiler here would shadow the real mpicc. Only set it when
    # a system mpicc exists, wrapped to keep the debug-flag stripping.
    mpicc_path = shutil.which("mpicc", path=env["PATH"])
    if mpicc_path:
        env.setdefault("MPICC", _make_compiler_wrapper(tmpdir, "mpicc", mpicc_path, sysroot))
    env.setdefault("AR", "ar")

    for key, wrapper in [
        ("CC", cc),
        ("CXX", cxx),
        ("CPP", cc),
        ("LDSHARED", cc),
        ("LDCXXSHARED", cxx),
    ]:
        _override_tool(env, key, wrapper)

    return env


def _load_text(maybe_file: str) -> str:
    if not path.exists(maybe_file):
        return ""

    with open(maybe_file, encoding="utf-8", errors="ignore") as f:
        return f.read()


def _load_pyproject_data(worktree: str) -> Optional[Dict[str, object]]:
    pyproject = path.join(worktree, "pyproject.toml")
    if not path.exists(pyproject):
        return None

    try:
        with open(pyproject, "rb") as f:
            return tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError):
        return None


def _legacy_metadata_conflicts_with_pyproject(worktree: str) -> bool:
    setup_py = path.join(worktree, "setup.py")
    pyproject_data = _load_pyproject_data(worktree)
    if not (pyproject_data and path.exists(setup_py)):
        return False

    build_system = pyproject_data.get("build-system", {})
    if not isinstance(build_system, dict):
        return False
    build_backend = build_system.get("build-backend")
    if build_backend not in _SETUPTOOLS_BACKENDS:
        return False

    project = pyproject_data.get("project")
    if not isinstance(project, dict) or not project:
        return False

    dynamic_value = project.get("dynamic", [])
    if not isinstance(dynamic_value, list):
        return False
    dynamic = {value for value in dynamic_value if isinstance(value, str)}
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
PARSER.add_argument("--monitor-memory", action="store_true")
PARSER.add_argument("--validate-anyarch", action="store_true")
PARSER.add_argument("--patch-strip", type=int, default=0, help="Strip count for patch (-p)")
PARSER.add_argument("--patch", action="append", default=[], dest="patches", help="Patch file to apply (repeatable)")
PARSER.add_argument("--execroot-marker", help="Token in env values to replace with the absolute execroot")
opts, _ = PARSER.parse_known_args()

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

# Preserve PATH so native sdist builds can find compilers (clang, gcc),
# and re-point CC/CXX/etc. through wrapper scripts in tmp_root so the
# Bazel-supplied workspace-relative compiler paths survive the cwd
# change into the worktree.
build_env = _compiler_env(tmp_root, opts.execroot_marker)

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
    raise SystemExit(1)

with TemporaryFile(mode="w+") as build_log:
    try:
        if opts.monitor_memory:
            # Generated build tools include this dependency only when the
            # corresponding wheel opts into monitoring.
            from uv.private.pep517_whl.memory_monitor import run_with_memory_monitor

            run_with_memory_monitor(
                cmd,
                cwd=t,
                env=build_env,
                stdout=build_log,
                wheel=path.basename(opts.srcarchive),
            )
        else:
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
