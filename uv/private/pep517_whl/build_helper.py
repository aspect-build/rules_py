#!/usr/bin/env python3

"""
A minimal python3 -m build wrapper

Mostly exists to allow debugging.
"""

from argparse import ArgumentParser
import os
import platform as _platform
import shlex
import shutil
import sys
from os import chmod, defpath, listdir, makedirs, path, pathsep
from subprocess import CalledProcessError, check_call, check_output, STDOUT
from tempfile import TemporaryFile

from uv.private.pep517_whl.memory_monitor import run_with_memory_profile

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib

_SETUPTOOLS_BACKENDS = (
    None,
    "setuptools.build_meta",
    "setuptools.build_meta:__legacy__",
)


# `$(CC)` etc. from the pep517_native_whl rule expands to a Bazel
# workspace-relative path (e.g. external/llvm+/toolchain/gcc) that
# resolves from the action execroot but not from the build
# subprocess's cwd inside the unpacked worktree. To keep CC reachable
# after that cwd change, we drop a tiny wrapper into tmp_root (which
# is absolute, so its path survives the cwd change) and point CC /
# CXX / CPP / LDSHARED / LDCXXSHARED at the wrapper. The wrapper
# strips `-fdebug-default-version=4` (older toolchains reject it)
# and then `execv`s the compiler at its resolved absolute path.
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


def _darwin_sysroot():
    """Return the macOS SDK path, or None if unavailable."""
    if _platform.system() != "Darwin":
        return None
    try:
        return check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    except Exception:
        return None


def _resolve_compiler_path(env, key, default):
    """Extract the real compiler from the environment and resolve it to an absolute path."""
    current = env.get(key)
    if not current:
        return default
    parts = shlex.split(current)
    if not parts:
        return default
    compiler = parts[0]
    if os.path.isabs(compiler):
        return compiler
    return os.path.abspath(compiler)


def _make_compiler_wrapper(tmpdir, name, compiler_path, sysroot=None):
    wrapper = path.join(tmpdir, ".aspect_rules_py_compilers", name)
    makedirs(path.dirname(wrapper), exist_ok=True)
    with open(wrapper, "w") as f:
        f.write(_COMPILER_WRAPPER.format(
            debug_flag=_DEBUG_FLAG,
            compiler_path=compiler_path,
            name=name,
            sysroot=sysroot,
        ))
    chmod(wrapper, 0o755)
    return wrapper


def _override_tool(env, key, wrapper):
    current = env.get(key)
    if not current:
        return
    parts = shlex.split(current)
    if parts:
        parts[0] = wrapper
        env[key] = shlex.join(parts)


def _compiler_env(tmpdir):
    env = dict(os.environ)
    env["PATH"] = pathsep.join([
        path.dirname(sys.executable),
        env.get("PATH", defpath),
    ])
    env["TMP"] = tmpdir
    env["TEMP"] = tmpdir
    env["TEMPDIR"] = tmpdir

    cc_path = _resolve_compiler_path(env, "CC", "cc")
    cxx_path = _resolve_compiler_path(env, "CXX", "c++")

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
PARSER.add_argument("--monitor-memory", action="store_true")
PARSER.add_argument("--validate-anyarch", action="store_true")
PARSER.add_argument("--patch-strip", type=int, default=0, help="Strip count for patch (-p)")
PARSER.add_argument("--patch", action="append", default=[], dest="patches", help="Patch file to apply (repeatable)")
opts, args = PARSER.parse_known_args()

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
build_env = _compiler_env(tmp_root)

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
        run_with_memory_profile(
            cmd,
            cwd=t,
            env=build_env,
            stdout=build_log,
            wheel=path.basename(opts.srcarchive),
            monitor=opts.monitor_memory,
        )
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
