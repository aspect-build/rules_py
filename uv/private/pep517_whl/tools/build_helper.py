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
import re
import shlex
import shutil
import sys
import textwrap
from os import chmod, defpath, listdir, makedirs, path, pathsep
from subprocess import CalledProcessError, check_call, check_output, STDOUT, run
from tempfile import TemporaryFile

try:
    tomllib = importlib.import_module("tomllib")
except ModuleNotFoundError:
    tomllib = importlib.import_module("tomli")

_SETUPTOOLS_BACKENDS = (
    None,
    "setuptools.build_meta",
    "setuptools.build_meta:__legacy__",
)


# Compiler commands must remain valid across working-directory changes.
# argv[0] must name the resolved driver because compilers may use its directory
# to locate sibling tools and resources. Clang does so under -no-canonical-prefixes:
# https://github.com/llvm/llvm-project/blob/llvmorg-22.1.4/clang/tools/driver/driver.cpp#L63-L78
_DEBUG_FLAG = "-fdebug-default-version=4"
_COMPILER_WRAPPER = """#!/usr/bin/env python3
import os
import sys

filtered_args = [arg for arg in sys.argv[1:] if arg != "{debug_flag}"]
sysroot = {sysroot!r}
if sysroot and "-isysroot" not in filtered_args:
    filtered_args = ["-isysroot", sysroot] + filtered_args
os.execv("{compiler_path}", ["{compiler_path}"] + filtered_args)
"""


def _darwin_sysroot() -> str | None:
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


def _resolve_compiler_path(env: dict[str, str], key: str, default: str) -> str:
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


def _local_cxx_companion(current: str | None, compiler_path: str) -> str:
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
    sysroot: str | None = None,
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


def _override_tool(env: dict[str, str], key: str, wrapper: str) -> None:
    current = env.get(key)
    if not current:
        return
    parts = shlex.split(current)
    if parts:
        parts[0] = wrapper
        env[key] = shlex.join(parts)


def _absolutize_tool_paths(env: dict[str, str]) -> None:
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


# --- Cross-compilation support -------------------------------------------
#
# Reduced to what setuptools-family backends need. Deferred to the slices
# that exercise them: meson cross files, CMake toolchain files, cargo env,
# lld discovery, -nostdlib++ static runtime archives, probe-executable
# static linking, and the darwin-exec ar/libtool translation.


def _write_generated_file(file_path: str, content: str, executable: bool = False) -> str:
    """Write content to file_path, creating parent dirs. Returns file_path for chaining."""
    makedirs(path.dirname(file_path), exist_ok=True)
    with open(file_path, "w") as f:
        f.write(content)
    if executable:
        chmod(file_path, 0o755)
    return file_path


_SYSROOT_FLAG_PREFIXES = ("--sysroot", "-isysroot")


def _absolutize_sysroot_flags(flags: str) -> str:
    """Absolutize sysroot values inside a flag string (CFLAGS, LDSHAREDFLAGS).

    Must run while the process is still in the execroot; the backend splices
    these env strings into commands it runs from inside the unpacked sdist,
    where an execroot-relative sysroot no longer resolves. A later relative
    "--sysroot" would also silently override the wrapper's absolute one —
    the clang driver honors the last occurrence.
    """
    parts = shlex.split(flags)
    result = []
    i = 0
    while i < len(parts):
        p = parts[i]
        flag, sep, value = p.partition("=")
        if sep and flag in _SYSROOT_FLAG_PREFIXES:
            p = "{}={}".format(flag, _absolutize_path(value))
        elif p in _SYSROOT_FLAG_PREFIXES and i + 1 < len(parts):
            result.append(p)
            result.append(_absolutize_path(parts[i + 1]))
            i += 2
            continue
        result.append(p)
        i += 1
    return shlex.join(result)


_IDENTITY_FLAG_PREFIXES = (
    "-target",
    "--target",
    "--sysroot",
    "-isysroot",
    "-mmacosx-version-min",
)


def _get_wrapper_flags(cflags: str) -> list[str]:
    """Extract identity flags (-target, --sysroot, -isysroot, ...) from CFLAGS.

    The PEP 517 backend (setuptools, meson-python) may strip these when
    constructing its own compile commands; the cross wrapper re-injects them
    on every invocation so the real compiler always targets the right
    platform. Sysroot values are absolutized first (see
    _absolutize_sysroot_flags for why that must happen in the execroot).
    """
    parts = shlex.split(_absolutize_sysroot_flags(cflags))
    result = []
    i = 0
    while i < len(parts):
        p = parts[i]
        if any(p == prefix or p.startswith(prefix + "=") for prefix in _IDENTITY_FLAG_PREFIXES):
            result.append(p)
            if "=" not in p and i + 1 < len(parts) and not parts[i + 1].startswith("-"):
                result.append(parts[i + 1])
                i += 1
        i += 1
    return result


_DROP_LINKER_FLAGS = frozenset({
    "-Wl,--start-group",
    "-Wl,--end-group",
    "-Wl,--as-needed",
    "-Wl,--allow-shlib-undefined",
    "-Wl,-O1",
    "-Wl,-start_group",
    "-Wl,-end_group",
    "-bundle",
    "STRIP_DEBUG_SYMBOLS",
})

_DROP_LINKER_PAIRS = frozenset({
    "-arch",
    "-undefined",
    "-current_version",
    "-compatibility_version",
    "-install_name",
})

_DROP_LINKER_PREFIXES = (
    "-mmacosx-version-min",
)

_CROSS_COMPILER_WRAPPER = """#!/usr/bin/env python3
import os
import sys

args = sys.argv[1:]
wrapper_flags = {wrapper_flags!r}
drop_exact = {drop_exact!r}
drop_pairs = {drop_pairs!r}
drop_prefixes = {drop_prefixes!r}
debug_flag = {debug_flag!r}
is_darwin = {is_darwin!r}
static_runtime_archives = {static_runtime_archives!r}

# Not a link if compiling/preprocessing (-c/-E/-S/-fsyntax-only) or if this
# is a compiler-introspection probe ("-print-*", "--version"): appending
# link-only flags there is noise at best.
is_link = True
for a in args:
    if a in ("-c", "-E", "-S", "-fsyntax-only", "--version", "-dumpmachine", "-dumpversion", "-###") or a.startswith("-print-"):
        is_link = False
        break

filtered = []
i = 0
while i < len(args):
    a = args[i]
    if a == debug_flag or a in drop_exact or any(a.startswith(p) for p in drop_prefixes):
        i += 1
        continue
    if a in drop_pairs and i + 1 < len(args):
        i += 2
        continue
    filtered.append(a)
    i += 1

# Shared-link spellings: "-shared" (ELF), "-bundle"/"-dynamiclib" (ld64).
# Scanned pre-filter: the darwin spellings are host-leak-dropped from
# `filtered` when the target is not darwin.
is_shared = any(a in ("-shared", "-bundle", "-dynamiclib") for a in args)
if is_link and is_shared and static_runtime_archives:
    # A -nostdlib++ toolchain (the BCR llvm module) carries its C++/unwind
    # runtime as toolchain inputs, never as link flags: without these
    # archives a C++ extension links with std::__1/_Unwind_* unresolved and
    # only explodes at dlopen time on the target. Archive semantics make
    # this safe on pure-C links: unused members are simply not pulled.
    filtered.extend(static_runtime_archives)
if is_darwin and is_link and is_shared:
    # Extension modules leave _Py* unresolved until dlopen; ld64 errors on
    # them by default (ELF linkers don't), so mirror CPython's own LDSHARED
    # unless the backend already passed it.
    if "dynamic_lookup" not in filtered and "-Wl,-undefined,dynamic_lookup" not in filtered:
        filtered.append("-Wl,-undefined,dynamic_lookup")

real = {compiler_path!r}
os.execv(real, [real] + wrapper_flags + filtered)
"""


def _make_cross_compiler_wrapper(
    tmpdir: str,
    name: str,
    compiler_path: str,
    wrapper_flags: list[str],
    is_darwin: bool = False,
    static_runtime_archives: list[str] | None = None,
) -> str:
    wrapper = path.join(tmpdir, ".aspect_rules_py_compilers", name)

    # "-bundle" and "-undefined dynamic_lookup" leak from a macOS *host*
    # sysconfig and break ELF linkers, but when the *target* is darwin they
    # are exactly how extension modules must link (unresolved _Py* symbols
    # bind at dlopen time) — keep them there.
    drop_exact = set(_DROP_LINKER_FLAGS)
    drop_pairs = set(_DROP_LINKER_PAIRS)
    if is_darwin:
        drop_exact.discard("-bundle")
        drop_pairs.discard("-undefined")

    return _write_generated_file(
        wrapper,
        _CROSS_COMPILER_WRAPPER.format(
            compiler_path=compiler_path,
            wrapper_flags=wrapper_flags,
            drop_exact=sorted(drop_exact),
            drop_pairs=sorted(drop_pairs),
            drop_prefixes=list(_DROP_LINKER_PREFIXES),
            debug_flag=_DEBUG_FLAG,
            is_darwin=is_darwin,
            static_runtime_archives=list(static_runtime_archives or []),
        ),
        executable=True,
    )


_MACOSX_DEPLOYMENT_TARGET_RE = re.compile(
    r"[\"']MACOSX_DEPLOYMENT_TARGET[\"']\s*:\s*[\"']?([0-9][0-9.]*)"
)


def _macosx_deployment_target(sysconfigdata_path: str) -> str | None:
    """The target interpreter's deployment target, from its sysconfigdata.

    The deployment version in wheel/platform tags is a property of the target
    interpreter's build, not a constant — regex the build_time_vars literal
    rather than importing it, since the file belongs to a foreign-platform
    interpreter this process must not execute code from.
    """
    try:
        with open(sysconfigdata_path, encoding="utf-8") as f:
            match = _MACOSX_DEPLOYMENT_TARGET_RE.search(f.read())
    except OSError:
        return None
    return match.group(1) if match else None


def _darwin_kernel_release(macos_deployment_target: str | None) -> str:
    """Fake os.uname() release consistent with the macOS deployment target.

    Darwin kernel majors track macOS marketing versions as 11→20 … 15→24;
    from the year-based scheme (26 = Darwin 25) it's major−1. Only consumers
    parsing a plausible kernel version matter here (ctypes' import does),
    so unknown/missing values fall back to the macOS 11 baseline.
    """
    try:
        major = int((macos_deployment_target or "").split(".")[0])
    except ValueError:
        major = 0
    if 11 <= major <= 15:
        return "{}.0.0".format(major + 9)
    if major >= 26:
        return "{}.0.0".format(major - 1)
    return "20.0.0"


_TITLECASE_OS = {"linux": "Linux", "darwin": "Darwin", "windows": "Windows"}
_SYS_PLATFORM = {"linux": "linux", "darwin": "darwin", "windows": "win32"}


_SITECUSTOMIZE_TEMPLATE = """\
import os
import platform
import sys
import collections

# ctypes parses os.uname().release at import time when the *host* is Darwin.
# Import it while uname and sys.platform are still real so the target's
# faked values never reach that parse.
try:
    import ctypes
except ImportError:
    pass

_machine = {machine!r}
_sysname = {sysname!r}
_release = {release!r}

# setup.py scripts branch on sys.platform to decide which sources to compile
# (psutil picks _psutil_osx.c vs _psutil_linux.c this way).
sys.platform = {sys_platform!r}

os.uname = lambda: os.uname_result((_sysname, "build", _release, "", _machine))

# CS_GLIBC_LIB_VERSION otherwise leaks the *host's* glibc version, which
# feeds manylinux-tag determination in pip/packaging/subprocess.
if hasattr(os, "confstr"):
    _real_confstr = os.confstr

    def _confstr(name):
        if name == "CS_GLIBC_LIB_VERSION":
            return "glibc_unknown"
        return _real_confstr(name)

    os.confstr = _confstr

# platform.uname_result.processor is a lazily-computed property that falls
# back to the real host on this field, so build our own namedtuple instead
# of the real type (mirrors crossenv's platform-patch.py).
_PlatformUname = collections.namedtuple("uname_result", "system node release version machine processor")
_platform_uname = _PlatformUname(_sysname, "build", _release, "", _machine, _machine)

platform.uname = lambda: _platform_uname
platform.system = lambda: _sysname
platform.machine = lambda: _machine
platform.libc_ver = lambda *a, **k: ("", "")

# packaging.tags derives its arch from sysconfig.get_platform() (already
# faked via $_PYTHON_HOST_PLATFORM); only the manylinux gate needs the
# top-level _manylinux hook packaging itself looks for.
"""

_MANYLINUX_HOOK = """\
# Cross build: we have no verified manylinux compatibility for the target
# (no target glibc version is threaded through yet), so refuse rather than
# silently claim host-arch manylinux tags are usable on the target.
def manylinux_compatible(tag_major, tag_minor, tag_arch):
    return False


manylinux1_compatible = False
manylinux2010_compatible = False
manylinux2014_compatible = False
"""


def _generate_cross_site(
    tmpdir: str,
    target_os: str,
    target_cpu: str,
    macos_deployment_target: str | None = None,
) -> str:
    """sitecustomize + _manylinux hook faking the target's runtime identity.

    sysconfig is already faked via env vars CPython itself reads
    (_PYTHON_HOST_PLATFORM, _PYTHON_SYSCONFIGDATA_NAME), but setup.py
    scripts also branch on os.uname()/platform.machine() directly, which
    env vars can't reach. sitecustomize.py runs on interpreter startup —
    before any backend code — and patches os/platform in place. Modeled on
    crossenv, minus what rules_py doesn't need.
    """
    site_dir = path.join(tmpdir, ".cross_site")

    # ctypes' own import does int(os.uname().release.split(".")[0]) on Darwin,
    # so the faked release must parse as a Darwin kernel version there —
    # derived from the target's deployment target so both stay consistent.
    # Linux keeps "": nothing on that path parses it.
    release = _darwin_kernel_release(macos_deployment_target) if target_os == "darwin" else ""
    # macOS reports "arm64", never the Bazel constraint's "aarch64" —
    # setup.py scripts branch on platform.machine() == "arm64", and the
    # faked identity must agree with the wheel tag derived elsewhere.
    machine = "arm64" if target_os == "darwin" and target_cpu == "aarch64" else target_cpu
    _write_generated_file(
        path.join(site_dir, "sitecustomize.py"),
        _SITECUSTOMIZE_TEMPLATE.format(
            machine=machine,
            sysname=_TITLECASE_OS.get(target_os, target_os),
            release=release,
            sys_platform=_SYS_PLATFORM.get(target_os, target_os),
        ),
    )
    _write_generated_file(path.join(site_dir, "_manylinux.py"), _MANYLINUX_HOOK)
    return site_dir


def _compiler_env(
    tmpdir: str,
    execroot_marker: str | None = None,
    cross: bool = False,
    target_os: str = "",
    target_cpu: str = "",
) -> dict[str, str]:
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
    # Some build deps (meson-python's ninja, maturin) ship plain wheel-data
    # executables under <whl_install output>/bin, which venv assembly never
    # merges (it only merges lib/site-packages) — so they land on neither
    # sys.path nor PATH. They are still real runfiles; walk the runfiles
    # roots for whl_install bin/ dirs and put those on PATH.
    bin_dirs = []
    for runfiles_root in sys.path:
        if not path.isdir(runfiles_root) or "runfiles" not in runfiles_root:
            continue
        for entry in os.listdir(runfiles_root):
            bin_dir = path.join(runfiles_root, entry, "actual_install.install", "bin")
            if path.isdir(bin_dir):
                bin_dirs.append(bin_dir)

    env["PATH"] = pathsep.join([
        path.dirname(sys.executable),
        *bin_dirs,
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

    if cross:
        # Toolchain flag strings (from cc_layer.bzl) contain execroot-relative
        # sysroots; absolutize while still in the execroot, before the backend
        # chdirs into the unpacked sdist.
        # LDFLAGS included: distutils' customize_compiler appends $LDFLAGS
        # after $LDSHARED, so a relative --sysroot there would override the
        # wrapper's absolute one (the driver honors the last occurrence).
        for key in ("CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "LDSHAREDFLAGS"):
            if env.get(key):
                env[key] = _absolutize_sysroot_flags(env[key])

        # The target interpreter's Python.h/pyconfig.h must shadow the exec
        # runtime's: distutils still injects the running interpreter's
        # include path, but CFLAGS-supplied -I directories are searched
        # first.
        target_include = env.pop("RULES_PY_TARGET_INCLUDE", "")
        if target_include:
            include_flag = "-I" + _absolutize_path(target_include)
            for key in ("CFLAGS", "CXXFLAGS"):
                env[key] = (include_flag + " " + env.get(key, "")).strip()

        wrapper_flags = _get_wrapper_flags(env.get("CFLAGS", ""))
        is_darwin_target = target_os == "darwin"

        # The -nostdlib++ toolchain's C++/unwind runtime archives, extracted
        # by cc_layer.bzl from static_runtime_lib. Ordered for single-pass
        # archive resolution: libc++ pulls from libc++abi, which pulls from
        # libunwind.
        static_runtime = [
            _absolutize_path(p)
            for p in env.pop("RULES_PY_CXX_STATIC_RUNTIME", "").split(":")
            if p
        ]
        runtime_rank = {"libc++.a": 0, "libc++abi.a": 1, "libunwind.a": 2}
        static_runtime.sort(key=lambda p: runtime_rank.get(path.basename(p), 3))

        cc = _make_cross_compiler_wrapper(tmpdir, "cc", cc_path, wrapper_flags, is_darwin=is_darwin_target, static_runtime_archives=static_runtime)
        cxx = _make_cross_compiler_wrapper(tmpdir, "c++", cxx_path, wrapper_flags, is_darwin=is_darwin_target, static_runtime_archives=static_runtime)
    else:
        cc = _make_compiler_wrapper(tmpdir, "cc", cc_path, sysroot)
        cxx = _make_compiler_wrapper(tmpdir, "c++", cxx_path, sysroot)

    env.setdefault("CC", cc)
    env.setdefault("CXX", cxx)

    if cross:
        ldshared_flags = env.get("LDSHAREDFLAGS", "")
        env["LDSHARED"] = cc + ((" " + ldshared_flags) if ldshared_flags else "")
        env["LDCXXSHARED"] = cxx + ((" " + ldshared_flags) if ldshared_flags else "")

        deployment_target = None
        target_sysconfig = env.get("RULES_PY_TARGET_SYSCONFIGDATA")
        if target_sysconfig and path.exists(target_sysconfig):
            sysconfig_dir = path.join(tmpdir, ".target_sysconfig")
            makedirs(sysconfig_dir, exist_ok=True)
            shutil.copy(target_sysconfig, sysconfig_dir)
            module_name = path.basename(target_sysconfig)[:-3]
            env["_PYTHON_SYSCONFIGDATA_NAME"] = module_name
            env["PYTHONPATH"] = sysconfig_dir + pathsep + env.get("PYTHONPATH", "")

            # The analysis-time _PYTHON_HOST_PLATFORM can only guess
            # macosx-11.0; the target interpreter's sysconfig knows the real
            # deployment version its wheel tags must carry. distutils'
            # get_platform() also honors $MACOSX_DEPLOYMENT_TARGET directly.
            if target_os == "darwin":
                deployment_target = _macosx_deployment_target(target_sysconfig)
                if deployment_target:
                    env.setdefault("MACOSX_DEPLOYMENT_TARGET", deployment_target)
                    cpu = "arm64" if target_cpu == "aarch64" else target_cpu
                    env["_PYTHON_HOST_PLATFORM"] = "macosx-{}-{}".format(deployment_target, cpu)

        if target_os and target_cpu:
            site_dir = _generate_cross_site(tmpdir, target_os, target_cpu, deployment_target)
            env["PYTHONPATH"] = site_dir + pathsep + env.get("PYTHONPATH", "")

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


def _load_pyproject_data(worktree: str) -> dict[str, object] | None:
    pyproject = path.join(worktree, "pyproject.toml")
    if not path.exists(pyproject):
        return None

    try:
        with open(pyproject, "rb") as f:
            return tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError):
        return None



# numpy's longdouble probe outputs (numpy/_core/meson.build), keyed by the
# target ABI: x86 keeps the 80-bit x87 format padded to 16 bytes, aarch64
# glibc uses IEEE binary128, and Apple aarch64 aliases long double to double.
_MESON_LONGDOUBLE_FORMAT = {
    ("darwin", "aarch64"): "IEEE_DOUBLE_LE",
    ("darwin", "x86_64"): "INTEL_EXTENDED_16_BYTES_LE",
    ("linux", "aarch64"): "IEEE_QUAD_LE",
    ("linux", "x86_64"): "INTEL_EXTENDED_16_BYTES_LE",
}


def _generate_meson_cross_file(
    tmpdir: str,
    build_env: dict[str, str],
    target_os: str,
    target_cpu: str,
) -> str:
    """Cross file for meson-python.

    meson-python only auto-synthesizes a cross file for macOS
    ARCHFLAGS/cibuildwheel/iOS; a Linux-arch cross build configures as
    native and meson fails running its compiler sanity-check binary.
    `needs_exe_wrapper = true` makes meson skip those runs; projects calling
    `cc.run()` directly get meson's explicit cross-environment error — an
    honest limitation until an emulator-backed exe_wrapper lands with the
    execution slice.

    The longdouble property is numpy's documented cross recipe: its
    meson.build reads this external property and only falls back to a
    cc.run() probe when it is absent (numpy gh-23972). The value is an ABI
    constant of (os, cpu), so bake it in.
    """
    longdouble_line = ""
    longdouble_format = _MESON_LONGDOUBLE_FORMAT.get((target_os, target_cpu))
    if longdouble_format:
        longdouble_line = "longdouble_format = '{}'\n".format(longdouble_format)
    return _write_generated_file(
        path.join(tmpdir, "cross_file.ini"),
        textwrap.dedent("""\
            [binaries]
            c = '{cc}'
            cpp = '{cxx}'
            ar = '{ar}'
            strip = '{strip}'

            [host_machine]
            system = '{system}'
            cpu_family = '{cpu_family}'
            cpu = '{cpu}'
            endian = 'little'

            [properties]
            needs_exe_wrapper = true
            {longdouble_line}""").format(
            cc=build_env["CC"],
            cxx=build_env["CXX"],
            longdouble_line=longdouble_line,
            ar=build_env.get("AR", "ar"),
            strip=build_env.get("STRIP", "strip"),
            system=target_os,
            cpu_family=target_cpu,
            cpu=target_cpu,
        ),
    )


def _build_backend(pyproject_data: dict[str, object] | None) -> str | None:
    """The [build-system].build-backend value, or None when undeclared."""
    build_system = (pyproject_data or {}).get("build-system", {})
    if not isinstance(build_system, dict):
        return None
    backend = build_system.get("build-backend")
    return backend if isinstance(backend, str) else None


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


def _wheel_platform_identity(target_os: str, target_cpu: str) -> tuple[str, str]:
    """The wheel platform-tag OS and CPU spellings for a Bazel OS/CPU constraint pair."""
    if target_os == "darwin":
        wheel_os = "macosx"
        wheel_cpu = "arm64" if target_cpu == "aarch64" else target_cpu
    elif target_os == "windows":
        wheel_os = "win"
        if target_cpu == "x86_64":
            wheel_cpu = "amd64"
        elif target_cpu == "aarch64":
            wheel_cpu = "arm64"
        else:
            wheel_cpu = target_cpu
    else:
        wheel_os = target_os
        if target_cpu == "x86":
            wheel_cpu = "i686"
        elif target_cpu == "arm":
            wheel_cpu = "armv7l"
        else:
            wheel_cpu = target_cpu
    return wheel_os, wheel_cpu


def _wheel_platform_error(
    wheel_filename: str,
    target_os: str,
    target_cpu: str,
    host_os: str | None = None,
) -> str | None:
    """Check a built wheel's platform tag against the requested target platform.

    Returns an error message when the tag names the wrong platform, None when
    it matches or no target was requested. The platform tag is the last
    dash-separated component of the filename (PEP 427); -none-any wheels are
    exempt — they carry no platform identity. host_os is injectable for tests
    and defaults to the running host.
    """
    if not target_os or not target_cpu:
        return None
    if wheel_filename.endswith("-none-any.whl"):
        return None

    platform_tag = wheel_filename.rsplit("-", 1)[-1].rsplit(".", 1)[0].lower()
    expected_os, expected_cpu = _wheel_platform_identity(target_os, target_cpu)

    if host_os is None:
        host_os = _platform.system().lower()
    host_wheel_os, _ = _wheel_platform_identity(host_os, "")

    # A tag naming the host's OS on a foreign-target build is the signature
    # of the backend compiling for the machine it runs on: report it as the
    # leak it is rather than a generic mismatch.
    if target_os != host_os and host_wheel_os in platform_tag:
        return (
            "Error: wheel platform tag '{}' contains exec host OS '{}' instead of "
            "target OS '{}'.".format(platform_tag, host_wheel_os, expected_os)
        )
    if expected_os not in platform_tag:
        return "Error: wheel platform tag '{}' does not contain target OS '{}'.".format(platform_tag, expected_os)

    # macOS universal2 wheels carry both architectures in one binary; either
    # darwin CPU target is satisfied by them.
    if target_os == "darwin" and "universal2" in platform_tag:
        return None
    if expected_cpu not in platform_tag:
        return "Error: wheel platform tag '{}' does not contain target CPU '{}'.".format(platform_tag, expected_cpu)
    return None


PARSER = ArgumentParser()
PARSER.add_argument("srcarchive")
PARSER.add_argument("output", help="Path the single built wheel is written to")
PARSER.add_argument("--monitor-memory", action="store_true")
PARSER.add_argument("--validate-anyarch", action="store_true")
PARSER.add_argument("--patch-strip", type=int, default=0, help="Strip count for patch (-p)")
PARSER.add_argument("--patch", action="append", default=[], dest="patches", help="Patch file to apply (repeatable)")
PARSER.add_argument("--execroot-marker", help="Token in env values to replace with the absolute execroot")
PARSER.add_argument("--cross", action="store_true", help="Cross-compilation mode: target platform != exec platform")
PARSER.add_argument("--target-os", default="", help="Target platform OS the wheel must be tagged for (linux, darwin, windows)")
PARSER.add_argument("--target-cpu", default="", help="Target platform CPU the wheel must be tagged for (x86_64, aarch64, ...)")

def main() -> None:
    opts, _ = PARSER.parse_known_args()

    tmp_root = path.abspath(opts.output) + ".tmp"
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


    # Backends take an output directory, not a file: build into a scratch dir.
    outdir = path.join(tmp_root, "dist")
    makedirs(outdir)

    # Preserve PATH so native sdist builds can find compilers (clang, gcc),
    # and re-point CC/CXX/etc. through wrapper scripts in tmp_root so the
    # Bazel-supplied workspace-relative compiler paths survive the cwd
    # change into the worktree.
    build_env = _compiler_env(
        tmp_root,
        opts.execroot_marker,
        cross=opts.cross,
        target_os=opts.target_os,
        target_cpu=opts.target_cpu,
    )

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

        # meson-python only synthesizes its own cross file for macOS
        # ARCHFLAGS/cibuildwheel shapes; everything else configures as a
        # native build and fails meson's compiler sanity checks. Hand it
        # ours (see _generate_meson_cross_file).
        if opts.cross and _build_backend(_load_pyproject_data(t)) == "mesonpy":
            cross_file = _generate_meson_cross_file(tmp_root, build_env, opts.target_os, opts.target_cpu)
            cmd += ["-C", "setup-args=--cross-file=" + cross_file]
    else:
        print("Error: Unable to detect build command! Neither pyproject.toml nor setup.py found!", file=sys.stderr)
        raise SystemExit(1)

    with TemporaryFile(mode="w+") as build_log:
        try:
            if opts.monitor_memory:
                # Generated build tools include this dependency only when the
                # corresponding wheel opts into monitoring.
                from uv.private.pep517_whl.tools.memory_monitor import run_with_memory_monitor

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

    if len(inventory) != 1:
        print("Error: Expected exactly one built wheel, found {}!\nSee {} for the sandbox".format(len(inventory), t), file=sys.stderr)
        exit(1)

    if opts.validate_anyarch and not inventory[0].endswith("-none-any.whl"):
        print("Error: Target was anyarch but built a none-any wheel!\nSee {} for the sandbox".format(t), file=sys.stderr)
        exit(1)

    tag_error = _wheel_platform_error(inventory[0], opts.target_os, opts.target_cpu)
    if tag_error:
        print("{}\nSee {} for the sandbox".format(tag_error, t), file=sys.stderr)
        exit(1)

    os.replace(path.join(outdir, inventory[0]), path.abspath(opts.output))


if __name__ == "__main__":
    main()
