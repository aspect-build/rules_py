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
from typing import Dict, List, Optional

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


def _local_cxx_companion(current: Optional[str], compiler_path: str) -> str:
    """Select an executable same-directory C++ peer for a direct local C driver."""
    parts = shlex.split(current or "")
    if not parts or not path.isabs(parts[0]):
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
        cxx_path = _local_cxx_companion(env.get("CXX"), cxx_path)

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


def _load_cc_deps_info(info_path: str, execroot_marker: Optional[str]) -> Dict[str, List[str]]:
    """Load the cc_deps params file, re-anchoring its execroot-relative paths.

    The rule emits every path prefixed with `execroot_marker` because only
    execroot-relative paths exist at analysis time. build_helper still runs at
    the execroot here (the backend chdir happens in the child process), so
    `os.getcwd()` is the execroot the marker must expand to.
    """
    import json

    if not execroot_marker:
        # Defensive: the rule always pairs the two flags; without the marker the
        # paths below cannot be anchored.
        print(
            "Error: --cc-deps-info requires --execroot-marker to anchor its paths.",
            file=sys.stderr,
        )
        exit(1)

    with open(info_path, encoding="utf-8") as f:
        raw = json.load(f)

    execroot = os.getcwd()
    info: Dict[str, List[str]] = {}
    for key in ("compile_flags", "link_objects", "link_libraries", "link_flags"):
        values: List[str] = []
        for value in raw.get(key, []):
            resolved = value.replace(execroot_marker, execroot)
            if execroot_marker in resolved:
                print(
                    "Error: execroot marker survived substitution in cc_deps "
                    "{}: {!r}".format(key, resolved),
                    file=sys.stderr,
                )
                exit(1)
            values.append(resolved)
        info[key] = values
    return info


def _effective_build_backend(worktree: str) -> Optional[str]:
    """Return the declared PEP 517 backend, or None for the setuptools default.

    A missing pyproject.toml, `[build-system]` table, or `build-backend` key all
    mean the legacy setuptools path (None is in `_SETUPTOOLS_BACKENDS`), which
    still honors DIST_EXTRA_CONFIG.
    """
    pyproject_data = _load_pyproject_data(worktree)
    if not pyproject_data:
        return None
    build_system = pyproject_data.get("build-system", {})
    if not isinstance(build_system, dict):
        return None
    backend = build_system.get("build-backend")
    return backend if isinstance(backend, str) else None


def _require_setuptools_floor() -> None:
    """Fail unless the build venv's setuptools understands DIST_EXTRA_CONFIG."""
    from importlib.metadata import PackageNotFoundError, version

    # DIST_EXTRA_CONFIG landed in setuptools 65.4.0; older setuptools silently
    # ignores the [build_ext] config we hand it, dropping the linked archives.
    try:
        found = version("setuptools")
    except PackageNotFoundError:
        print(
            "Error: cc_deps requires setuptools >= 65.4.0 in the build "
            "environment, but setuptools is not installed. Add setuptools to your "
            "uv.lock / default_build_dependencies.",
            file=sys.stderr,
        )
        exit(1)

    parts = found.split(".")
    try:
        version_tuple = (int(parts[0]), int(parts[1]) if len(parts) > 1 else 0)
    except (IndexError, ValueError):
        print(
            "Error: cc_deps requires setuptools >= 65.4.0, but could not parse the "
            "installed setuptools version {!r}.".format(found),
            file=sys.stderr,
        )
        exit(1)

    if version_tuple < (65, 4):
        print(
            "Error: cc_deps requires setuptools >= 65.4.0 (for DIST_EXTRA_CONFIG), "
            "but the build environment has {}. Update setuptools in your uv.lock / "
            "default_build_dependencies.".format(found),
            file=sys.stderr,
        )
        exit(1)


def _has_whitespace(value: str) -> bool:
    return any(character.isspace() for character in value)


def _cc_deps_include_path(flag: str) -> Optional[str]:
    """Return the directory carried by an -I/-iquote/-isystem/-F flag, else None."""
    for prefix in ("-iquote", "-isystem", "-I", "-F"):
        if flag.startswith(prefix):
            return flag[len(prefix):]
    return None


def _reject_unsplittable_cc_deps(info: Dict[str, List[str]]) -> None:
    """Reject values setuptools/CPPFLAGS/LDFLAGS would split, naming the offender.

    setuptools splits `[build_ext] link_objects` and `libraries` on whitespace
    or comma, and CPPFLAGS/LDFLAGS are word-split downstream, so a path
    containing either survives neither. The execroot itself can carry a space
    (a user home directory), so this is exactly the case the guard catches.
    """
    # os.pathsep does not appear in setuptools' link_objects split rule
    # (whitespace/comma only), but the guard keeps it as an over-conservative
    # fail-safe: a colon-bearing archive path has no legitimate source here.
    for link_object in info["link_objects"]:
        if _has_whitespace(link_object) or "," in link_object or pathsep in link_object:
            print(
                "Error: cc_deps link object path {!r} contains whitespace, a "
                "comma, or {!r}; setuptools splits [build_ext] link_objects on "
                "whitespace/comma and would mangle it. This usually means the "
                "Bazel output base (execroot) contains a space; choose an "
                "--output_base without spaces.".format(link_object, pathsep),
                file=sys.stderr,
            )
            exit(1)
    for library in info["link_libraries"]:
        if _has_whitespace(library) or "," in library:
            print(
                "Error: cc_deps library name {!r} contains whitespace or a "
                "comma; setuptools splits [build_ext] libraries on those and "
                "would mangle it.".format(library),
                file=sys.stderr,
            )
            exit(1)
    # -D defines are deliberately unguarded (binding decision): they carry
    # symbols, not paths, and CPPFLAGS is the only channel that can express K=V.
    for flag in info["compile_flags"]:
        include = _cc_deps_include_path(flag)
        if include is not None and _has_whitespace(include):
            print(
                "Error: cc_deps compile search path {!r} contains whitespace; "
                "CPPFLAGS is word-split downstream and would mangle it. This "
                "usually means the Bazel output base (execroot) contains a space; "
                "choose an --output_base without spaces.".format(include),
                file=sys.stderr,
            )
            exit(1)
    # LDFLAGS is word-split downstream, so a whitespace-bearing token is
    # unrepresentable, whether it's an execroot-anchored path
    # (e.g. -Wl,--version-script,<execroot>/.../vs.lds) or a user linkopt that
    # happens to carry a space. Guard every link flag, not just the
    # execroot-anchored ones.
    for flag in info["link_flags"]:
        if _has_whitespace(flag):
            print(
                "Error: cc_deps link flag {!r} contains whitespace; it is "
                "appended to LDFLAGS, which is word-split downstream, so no "
                "single flag can carry a space. This usually means the Bazel "
                "output base (execroot) contains a space; choose an "
                "--output_base without spaces.".format(flag),
                file=sys.stderr,
            )
            exit(1)


def _package_build_ext_option(worktree: str, option: str) -> Optional[str]:
    """Return a `[build_ext]` option value from the package's setup.cfg, if any.

    DIST_EXTRA_CONFIG REPLACES (never merges) same-named options, so the
    package's own value has to be folded back in explicitly. Tolerant of a
    missing setup.cfg; warns but continues if an existing one will not parse.
    """
    import configparser

    setup_cfg = path.join(worktree, "setup.cfg")
    if not path.exists(setup_cfg):
        return None

    parser = configparser.ConfigParser(interpolation=None)
    try:
        parser.read(setup_cfg, encoding="utf-8")
    except configparser.Error:
        print(
            "Warning: ignoring [build_ext] settings in {} (could not parse it).".format(setup_cfg),
            file=sys.stderr,
        )
        return None

    if parser.has_option("build_ext", option):
        return parser.get("build_ext", option)
    return None


def _merged_build_ext_value(worktree: str, option: str, values: List[str]) -> str:
    """Join our `values` for a [build_ext] option behind the package's own value."""
    ours = " ".join(values)
    package_value = _package_build_ext_option(worktree, option)
    if not package_value:
        return ours
    # configparser may return a multi-line value; collapse it to one physical
    # line so our generated cfg stays well-formed. The option is whitespace/comma
    # split downstream, so token semantics are preserved, and the package's
    # entries stay worktree-relative (they resolve because the backend's cwd is
    # the worktree).
    package_value = " ".join(package_value.split())
    return "{} {}".format(package_value, ours) if ours else package_value


def _build_extra_config_text(info: Dict[str, List[str]], worktree: str) -> str:
    """Render the DIST_EXTRA_CONFIG `[build_ext]` file for the link inputs.

    include_dirs and defines are deliberately omitted: they ride CPPFLAGS
    instead (a cfg `define` cannot express K=V macros, and CPPFLAGS reaches
    custom build commands too).
    """
    lines = ["[build_ext]"]
    if info["link_objects"]:
        lines.append("link_objects = {}".format(
            _merged_build_ext_value(worktree, "link_objects", info["link_objects"]),
        ))
    if info["link_libraries"]:
        lines.append("libraries = {}".format(
            _merged_build_ext_value(worktree, "libraries", info["link_libraries"]),
        ))
    return "\n".join(lines) + "\n"


def _append_cc_deps_env(env: Dict[str, str], key: str, additions: List[str]) -> None:
    """Append flags to an env var, preserving any user value as the prefix."""
    if not additions:
        return
    addition = " ".join(additions)
    existing = env.get(key)
    env[key] = "{} {}".format(existing, addition) if existing else addition


def _apply_cc_deps(
    env: Dict[str, str],
    info_path: str,
    execroot_marker: Optional[str],
    worktree: str,
    tmp_root: str,
) -> None:
    """Route cc_deps compile/link inputs into the setuptools build.

    Mutates `env` in place: appends compile flags to CPPFLAGS and exotic link
    flags to LDFLAGS, and points DIST_EXTRA_CONFIG at a `[build_ext]` file (in
    tmp_root, never the worktree) carrying the static archives and `-l`
    libraries. Only runs when `--cc-deps-info` was passed, so the no-cc_deps
    path is unchanged.
    """
    info = _load_cc_deps_info(info_path, execroot_marker)

    # cc_deps is a setuptools-only feature in v1; refuse other backends loudly
    # rather than silently dropping the inputs.
    backend = _effective_build_backend(worktree)
    if backend not in _SETUPTOOLS_BACKENDS:
        print(
            "Error: cc_deps is only supported with the setuptools build backend, "
            "but this package declares build-backend {!r}. cc_deps injects "
            "setuptools [build_ext] settings, which other backends ignore.".format(backend),
            file=sys.stderr,
        )
        exit(1)

    _require_setuptools_floor()

    # Never merge with a user-provided DIST_EXTRA_CONFIG (v1 owns it).
    if "DIST_EXTRA_CONFIG" in env:
        print(
            "Error: cc_deps needs DIST_EXTRA_CONFIG, but it is already set in the "
            "build environment. Remove it from `env` to use cc_deps.",
            file=sys.stderr,
        )
        exit(1)

    # DIST_EXTRA_CONFIG lives only in setuptools' local distutils.
    if env.get("SETUPTOOLS_USE_DISTUTILS") == "stdlib":
        print(
            "Error: cc_deps requires setuptools' local distutils, but "
            "SETUPTOOLS_USE_DISTUTILS=stdlib is set. Unset it (or set it to "
            "\"local\") to use cc_deps.",
            file=sys.stderr,
        )
        exit(1)
    env.setdefault("SETUPTOOLS_USE_DISTUTILS", "local")

    _reject_unsplittable_cc_deps(info)

    # The config file lives in tmp_root, never the worktree.
    config_path = path.join(tmp_root, "cc_deps_extra.cfg")
    with open(config_path, "w", encoding="utf-8") as f:
        f.write(_build_extra_config_text(info, worktree))
    env["DIST_EXTRA_CONFIG"] = config_path

    # Compose additively; any user CPPFLAGS/LDFLAGS stay in front.
    _append_cc_deps_env(env, "CPPFLAGS", info["compile_flags"])
    _append_cc_deps_env(env, "LDFLAGS", info["link_flags"])


PARSER = ArgumentParser()
PARSER.add_argument("srcarchive")
PARSER.add_argument("outdir")
PARSER.add_argument("--monitor-memory", action="store_true")
PARSER.add_argument("--validate-anyarch", action="store_true")
PARSER.add_argument("--patch-strip", type=int, default=0, help="Strip count for patch (-p)")
PARSER.add_argument("--patch", action="append", default=[], dest="patches", help="Patch file to apply (repeatable)")
PARSER.add_argument("--execroot-marker", help="Token in env values to replace with the absolute execroot")
PARSER.add_argument("--cc-deps-info", help="Path to the cc_deps compile/link params file to inject")
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

# cc_deps rides the same execroot cwd as _compiler_env: substitute the marker
# and inject the setuptools [build_ext] config before the backend chdirs.
if opts.cc_deps_info:
    _apply_cc_deps(build_env, opts.cc_deps_info, opts.execroot_marker, t, tmp_root)

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
