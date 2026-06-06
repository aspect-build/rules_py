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
from subprocess import CalledProcessError, check_call, check_output, STDOUT, run
from tempfile import TemporaryFile

try:
    import tomllib
except ModuleNotFoundError:
    try:
        import tomli as tomllib
    except ModuleNotFoundError:
        # Only needed for the legacy-metadata fallback check below; real
        # builds on Python < 3.11 get tomli through the build venv deps.
        tomllib = None

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


# Compiler/linker flags whose *next* token is a filesystem path.
_PATH_ARG_FLAGS = ("-I", "-L", "-isystem", "-iquote", "-idirafter", "-B", "-include", "--sysroot")

# Flag prefixes with the path attached to the flag itself (-Iexternal/...).
_PATH_PREFIX_FLAGS = ("--sysroot=", "-isystem", "-iquote", "-idirafter", "-I", "-L", "-B")


def _abs_if_execroot_relative(p, require_sep=False):
    """Absolutize `p` if it is a relative path that exists under the cwd.

    With require_sep, plain words like "ar" (resolved via PATH) are left
    alone and only multi-component paths are considered.
    """
    if not p or path.isabs(p):
        return p
    if require_sep and "/" not in p and os.sep not in p:
        return p
    if not path.exists(p):
        return p
    return path.abspath(p)


def _absolutize_token(tok):
    for flag in _PATH_PREFIX_FLAGS:
        if tok.startswith(flag) and len(tok) > len(flag):
            return flag + _abs_if_execroot_relative(tok[len(flag):])
    return _abs_if_execroot_relative(tok, require_sep=True)


def _absolutize_env_paths(env):
    """Rewrite execroot-relative paths in env values to absolute paths.

    Bazel expands make-variables like $(AR) or $(JAVABASE) and user-supplied
    -I/-L flags to execroot-relative paths (e.g. external/llvm+/bin/ar). The
    PEP 517 build backend runs with cwd inside the unpacked sdist worktree,
    where those paths no longer resolve for native build hooks (setup.py,
    meson, cmake, ...). Must be called while cwd is still the execroot.
    """
    for key, value in env.items():
        if not value:
            continue

        # Whole value is a single path (may contain spaces, e.g. JAVA_HOME).
        if not path.isabs(value) and ("/" in value or os.sep in value) and path.exists(value):
            env[key] = path.abspath(value)
            continue

        # PATH-style list (CPATH, LIBRARY_PATH, PKG_CONFIG_PATH, ...).
        if pathsep in value:
            env[key] = pathsep.join(
                _abs_if_execroot_relative(p, require_sep=True)
                for p in value.split(pathsep)
            )
            continue

        # Flag/argument string (CFLAGS, LDFLAGS, CC with extra args, ...).
        try:
            tokens = shlex.split(value)
        except ValueError:
            continue
        new_tokens = []
        path_arg = False
        for tok in tokens:
            if path_arg:
                new_tokens.append(_abs_if_execroot_relative(tok))
                path_arg = False
            elif tok in _PATH_ARG_FLAGS:
                new_tokens.append(tok)
                path_arg = True
            else:
                new_tokens.append(_absolutize_token(tok))
        if new_tokens != tokens:
            env[key] = shlex.join(new_tokens)


def _compiler_env(tmpdir):
    env = dict(os.environ)

    # Re-root execroot-relative env paths onto absolute ones while cwd is
    # still the execroot; the build subprocess below changes cwd into the
    # unpacked worktree where they would no longer resolve.
    _absolutize_env_paths(env)
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
    env.setdefault("MPICC", _make_compiler_wrapper(tmpdir, "mpicc", cc_path, sysroot))
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
    if tomllib is None or not path.exists(pyproject):
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
        check_call(
            ["patch", "-p{}".format(opts.patch_strip), "-i", path.abspath(patch_file)],
            cwd=t,
        )


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
