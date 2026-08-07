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


# Compiler commands must remain valid across working-directory changes.
# argv[0] must name the resolved driver because compilers may use its directory
# to locate sibling tools and resources. Clang does so under -no-canonical-prefixes:
# https://github.com/llvm/llvm-project/blob/llvmorg-22.1.4/clang/tools/driver/driver.cpp#L63-L78
_DEBUG_FLAG = "-fdebug-default-version=4"

# gcc_toolchain's tool_path for the cpp_compile/cpp_link_dynamic_library
# actions is plain "gcc", not "g++": Bazel toolchains dispatch C vs C++ by
# file extension/-x, not by driver name, and gcc_toolchain's link flags carry
# no -lstdc++. `-static-libstdc++` alone is a no-op there — that flag only
# modifies an *implicit* libstdc++ link that only the "g++" argv[0] spec adds
# in the first place. `-Wl,-Bstatic -lstdc++ -Wl,-Bdynamic` forces the static
# archive regardless of driver name, making a C++ extension self-contained
# instead of depending on the target's libstdc++.so.6 matching ours — and
# without it, cross-arch (and even native) C++ extensions can build and even
# import (borrowing symbols another already-loaded .so happened to pull in)
# yet fail once nothing else in the process provides them. GNU-ld-only
# syntax: skipped on Darwin, where clang++ already links libc++ implicitly.
_STATIC_LIBSTDCXX_FLAGS = ("-Wl,-Bstatic", "-lstdc++", "-Wl,-Bdynamic")

_COMPILER_WRAPPER = """#!/usr/bin/env python3
import os
import sys

filtered_args = [arg for arg in sys.argv[1:] if arg != "{debug_flag}"]
is_cxx = {is_cxx!r}
is_darwin = {is_darwin!r}
is_link = "-c" not in filtered_args
if is_cxx and is_link and not is_darwin:
    filtered_args = filtered_args + {static_libstdcxx_flags!r}
sysroot = {sysroot!r}
if sysroot and "-isysroot" not in filtered_args:
    filtered_args = ["-isysroot", sysroot] + filtered_args

# argv[0] must be the compiler's full path, not just its basename: GCC's
# driver resolves prefix-relative resources (libstdc++.a, LTO plugins) off
# argv[0], not /proc/self/exe. A basename-only argv[0] makes it silently
# search relative to our wrapper's own directory instead and miss them.
os.execv("{compiler_path}", ["{compiler_path}"] + filtered_args)
"""

_IDENTITY_FLAG_PREFIXES = (
    "-target",
    "--target",
    "--sysroot",
    "-isysroot",
    "-mmacosx-version-min",
)

_DROP_LINKER_FLAGS = frozenset({
    "-Wl,--start-group",
    "-Wl,--end-group",
    "-Wl,--as-needed",
    "-Wl,--allow-shlib-undefined",
    "-Wl,-O1",
    "-Wl,-start_group",
    "-Wl,-end_group",
    "-bundle",
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
lld_path = {lld_path!r}
debug_flag = {debug_flag!r}
is_cxx = {is_cxx!r}
is_darwin = {is_darwin!r}
static_libstdcxx_flags = {static_libstdcxx_flags!r}

is_link = "-c" not in args
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

# Standalone (non-"-shared") executables built by this cross toolchain are
# never the actual wheel deliverable — always some build tool's own
# throwaway sanity-check/feature-probe binary (e.g. meson's own compiler
# check, or a project's cc.run() call) that an exe_wrapper immediately
# executes under QEMU. Dynamically-linked target-arch PIE binaries hit a
# real qemu-user/glibc bug there ("Inconsistency detected by ld.so:
# ... DT_VERSYM ... Assertion failed") on process startup's own relocation
# path, verified independent of any toolchain mismatch (a single-toolchain
# hello-world binary reproduces it); statically linking sidesteps it
# entirely, since it never touches ld.so's dynamic-executable-startup path.
# The actual .so deliverables this wrapper also builds are unaffected —
# they always pass "-shared" and load via dlopen()'s own, unrelated path.
# Mutually exclusive with the static-libstdc++-only trick below: a trailing
# "-Wl,-Bdynamic" there would undo a preceding bare "-static" for whatever
# the driver appends after our args (libc included), reintroducing the same
# bug — and full static linking already covers libstdc++ too, making that
# partial trick redundant for a binary that's never shipped anyway.
is_shared = "-shared" in filtered
if is_link and not is_shared and not is_darwin:
    filtered.append("-static")
elif is_cxx and is_link and not is_darwin:
    filtered.extend(static_libstdcxx_flags)

if is_link and lld_path:
    os.environ.setdefault("PATH", "")
    os.environ["PATH"] = os.path.dirname(lld_path) + os.pathsep + os.environ["PATH"]
    if "-fuse-ld=lld" not in filtered:
        filtered.insert(0, "-fuse-ld=lld")

real = {compiler_path!r}
os.execv(real, [real] + wrapper_flags + filtered)
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


def _write_generated_file(file_path: str, content: str, executable: bool = False) -> str:
    """Write content to file_path, creating parent dirs. Returns file_path for chaining."""
    makedirs(path.dirname(file_path), exist_ok=True)
    with open(file_path, "w") as f:
        f.write(content)
    if executable:
        chmod(file_path, 0o755)
    return file_path


def _make_compiler_wrapper(
    tmpdir: str,
    name: str,
    compiler_path: str,
    sysroot: Optional[str] = None,
    is_cxx: bool = False,
    is_darwin: bool = False,
) -> str:
    wrapper = path.join(tmpdir, ".aspect_rules_py_compilers", name)
    return _write_generated_file(
        wrapper,
        _COMPILER_WRAPPER.format(
            debug_flag=_DEBUG_FLAG,
            compiler_path=compiler_path,
            sysroot=sysroot,
            is_cxx=is_cxx,
            is_darwin=is_darwin,
            static_libstdcxx_flags=list(_STATIC_LIBSTDCXX_FLAGS),
        ),
        executable=True,
    )


def _get_wrapper_flags(cflags: str) -> list[str]:
    """Extract identity flags (-target, --sysroot, -isysroot, ...) from CFLAGS.

    The PEP 517 backend (setuptools, meson-python) may strip these when
    constructing its own compile commands. The cross wrapper re-injects
    them on every invocation to guarantee the real compiler targets the
    correct platform.
    """
    parts = shlex.split(cflags)
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


def _find_lld(compiler_path: str) -> Optional[str]:
    """Locate ld.lld or ld64.lld next to the compiler, if present."""
    d = path.dirname(compiler_path)
    if not d:
        return None
    for name in ("ld.lld", "ld64.lld", "lld"):
        candidate = path.join(d, name)
        if path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def _make_cross_compiler_wrapper(
    tmpdir: str,
    name: str,
    compiler_path: str,
    wrapper_flags: list[str],
    lld_path: Optional[str] = None,
    is_cxx: bool = False,
    is_darwin: bool = False,
) -> str:
    wrapper = path.join(tmpdir, ".aspect_rules_py_compilers", name)
    return _write_generated_file(
        wrapper,
        _CROSS_COMPILER_WRAPPER.format(
            compiler_path=compiler_path,
            wrapper_flags=wrapper_flags,
            drop_exact=sorted(_DROP_LINKER_FLAGS),
            drop_pairs=sorted(_DROP_LINKER_PAIRS),
            drop_prefixes=list(_DROP_LINKER_PREFIXES),
            lld_path=lld_path,
            debug_flag=_DEBUG_FLAG,
            is_cxx=is_cxx,
            is_darwin=is_darwin,
            static_libstdcxx_flags=list(_STATIC_LIBSTDCXX_FLAGS),
        ),
        executable=True,
    )


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
    for key in ("JAVA_HOME", "JAVA", "CARGO", "RUSTC", "RULES_PY_RUST_HOST_SYSROOT", "ANT_HOME", "RULES_PY_ANT_BIN_DIR"):
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


def _compiler_env(
    tmpdir: str,
    execroot_marker: Optional[str] = None,
    cross: bool = False,
    target_os: str = "",
    target_cpu: str = "",
) -> Dict[str, str]:
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
    # A build dependency's console-script wrappers resolve their own bundled
    # binary via Python import machinery (ninja, meson), so they never need
    # PATH. Some (maturin) instead ship a plain wheel-data script under
    # <whl_install output>/bin — rules_py's venv assembly only merges each
    # dep's lib/site-packages into the shared venv, not its bin/, so that
    # script never lands on sys.path or PATH by itself. Its files are still
    # real runfiles under the runfiles root, just not indexed anywhere else,
    # so find it the same way Bazel's own runfiles resolution would: walk
    # the runfiles tree for a whl_install output's bin/ directory.
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

    # python-build-standalone interpreters (our python_interpreters toolchain)
    # bake their *original build-time* prefix into sysconfig's LIBDIR
    # (observed: "/install/lib", nonexistent once relocated into a Bazel
    # toolchain) — harmless for pure-Python builds, but anything that needs
    # to actually link against libpythonX.Y (meson's own Cython compiler
    # sanity check does, to link its transpiled-and-compiled test program)
    # fails with "cannot find -lpythonX.Y". The toolchain's own pkg-config
    # file resolves paths relative to itself instead (${pcfiledir}/../..),
    # so pointing PKG_CONFIG_PATH at it sidesteps the broken sysconfig value
    # entirely for any tool that tries pkg-config before falling back to it.
    interpreter_root = path.dirname(path.dirname(path.realpath(sys.executable)))
    pkgconfig_dir = path.join(interpreter_root, "lib", "pkgconfig")
    if path.isdir(pkgconfig_dir):
        env["PKG_CONFIG_PATH"] = pathsep.join([pkgconfig_dir, env.get("PKG_CONFIG_PATH", "")]).rstrip(pathsep)

    # Bazel expands tool paths relative to the execroot. Resolve them while the
    # helper still runs there; bare tool names deliberately remain on PATH.
    _absolutize_tool_paths(env)

    cc_path = _resolve_compiler_path(env, "CC", "cc")
    cxx_path = _resolve_compiler_path(env, "CXX", "c++")
    if env.pop("ASPECT_RULES_PY_INFER_CXX_COMPANION", None) == "1":
        cxx_path = _local_cxx_companion(env.get("CXX"), cxx_path)

    sysroot = _darwin_sysroot()
    is_darwin = target_os == "darwin" if cross else _platform.system() == "Darwin"

    if cross:
        wrapper_flags = _get_wrapper_flags(env.get("CFLAGS", ""))
        lld_path = _find_lld(cc_path)
        cc = _make_cross_compiler_wrapper(tmpdir, "cc", cc_path, wrapper_flags, lld_path, is_darwin=is_darwin)
        cxx = _make_cross_compiler_wrapper(tmpdir, "c++", cxx_path, wrapper_flags, lld_path, is_cxx=True, is_darwin=is_darwin)

        # gcc_toolchain's own layout (<root>/xbin/gcc, <root>/sysroot/...):
        # a target-arch binary linked by this compiler needs ITS glibc/loader
        # to run, not whatever the exec host or an unrelated toolchain (e.g.
        # our python_interpreters build) happens to provide. Only meson's
        # exe_wrapper (see _generate_meson_cross_file) uses this today.
        target_gcc_sysroot = path.join(path.dirname(path.dirname(cc_path)), "sysroot")
        if not is_darwin and path.isdir(target_gcc_sysroot):
            env["RULES_PY_TARGET_GCC_SYSROOT"] = target_gcc_sysroot
    else:
        cc = _make_compiler_wrapper(tmpdir, "cc", cc_path, sysroot, is_darwin=is_darwin)
        cxx = _make_compiler_wrapper(tmpdir, "c++", cxx_path, sysroot, is_cxx=True, is_darwin=is_darwin)

    env.setdefault("CC", cc)
    env.setdefault("CXX", cxx)

    if cross:
        ldshared_flags = env.get("LDSHAREDFLAGS", "")
        env["LDSHARED"] = cc + (" " + ldshared_flags if ldshared_flags else "")
        env["LDCXXSHARED"] = cxx + (" " + ldshared_flags if ldshared_flags else "")

        target_sysconfig = env.get("RULES_PY_TARGET_SYSCONFIGDATA")
        if target_sysconfig and path.exists(target_sysconfig):
            sysconfig_dir = path.join(tmpdir, ".target_sysconfig")
            makedirs(sysconfig_dir, exist_ok=True)
            shutil.copy(target_sysconfig, sysconfig_dir)
            module_name = path.basename(target_sysconfig)[:-3]
            env["_PYTHON_SYSCONFIGDATA_NAME"] = module_name
            env["PYTHONPATH"] = sysconfig_dir + pathsep + env.get("PYTHONPATH", "")

        if target_os and target_cpu:
            site_dir = _generate_cross_site(tmpdir, target_os, target_cpu)
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

    # maturin's PEP 517 wrapper (and setuptools-rust) locate cargo via
    # shutil.which("cargo"), not just $CARGO — otherwise they fall back to
    # auto-installing a Rust toolchain via the puccinialin package, which
    # isn't one of our declared build deps.
    cargo_path = env.get("CARGO")
    if cargo_path:
        env["PATH"] = pathsep.join([path.dirname(cargo_path), env.get("PATH", defpath)])

        # Cargo defaults its registry cache to $CARGO_HOME (~/.cargo), which
        # in the sandbox is a read-only path outside the action's writable
        # tree — give it a real, writable home instead.
        cargo_home = path.join(tmpdir, ".cargo_home")
        makedirs(cargo_home, exist_ok=True)
        env.setdefault("CARGO_HOME", cargo_home)

    # CMake's find_program(ANT_EXECUTABLE) (jpype1 et al.) needs ant on PATH.
    ant_bin_dir = env.pop("RULES_PY_ANT_BIN_DIR", None)
    if ant_bin_dir:
        env["PATH"] = pathsep.join([ant_bin_dir, env.get("PATH", defpath)])

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


# Our lowercase target_os values, Title-Cased for whatever tool wants that
# spelling: CMAKE_SYSTEM_NAME and the faked platform.system()/os.uname()
# sysname both use it.
_TITLECASE_OS = {"linux": "Linux", "darwin": "Darwin", "windows": "Windows"}


def _generate_cmake_toolchain_file(
    tmpdir: str,
    build_env: Dict[str, str],
    target_os: str,
    target_cpu: str,
) -> str:
    """Cross toolchain file for scikit-build-core/CMake.

    scikit-build-core's cross-compile detection only covers macOS
    ARCHFLAGS/CMAKE_OSX_ARCHITECTURES (see its builder.py); a generic
    Linux-arch cross build gets none of that, so CMake configures as a
    native build. It still compiles/links fine off $CC/$CXX, but
    CMAKE_STRIP falls back to `find_program`'s host `strip` rather than
    ours, which then rejects the foreign-arch .so ("Unable to recognise
    the format of the input file"). Setting CMAKE_SYSTEM_NAME also puts
    CMake into real CMAKE_CROSSCOMPILING mode.
    """
    return _write_generated_file(
        path.join(tmpdir, "cross_toolchain.cmake"),
        textwrap.dedent("""\
            set(CMAKE_SYSTEM_NAME {system})
            set(CMAKE_SYSTEM_PROCESSOR {processor})
            set(CMAKE_C_COMPILER {cc})
            set(CMAKE_CXX_COMPILER {cxx})
            set(CMAKE_AR {ar})
            set(CMAKE_STRIP {strip})
            """).format(
            system=_TITLECASE_OS.get(target_os, target_os),
            processor=target_cpu,
            cc=build_env["CC"],
            cxx=build_env["CXX"],
            ar=build_env.get("AR", "ar"),
            strip=build_env.get("STRIP", "strip"),
        ),
    )


_MESON_EXE_WRAPPER = """#!/usr/bin/env python3
import os
import sys

qemu_ld_prefix = {qemu_ld_prefix!r}
if qemu_ld_prefix:
    os.environ["QEMU_LD_PREFIX"] = qemu_ld_prefix
os.execv(sys.argv[1], sys.argv[1:])
"""


def _generate_meson_cross_file(
    tmpdir: str,
    build_env: Dict[str, str],
    target_os: str,
    target_cpu: str,
) -> str:
    """Cross file for meson-python.

    meson-python only auto-synthesizes a cross file for macOS ARCHFLAGS,
    cibuildwheel/Android, and iOS (see its __init__.py); a generic
    Linux-arch cross build gets none of that and configures as a native
    build, so meson tries to run its compiler sanity-check binary and
    fails with "not runnable". `needs_exe_wrapper` alone only covers
    meson's OWN compiler sanity checks (which just skip running anything
    when it's set) — some projects' meson.build also call `cc.run()`
    directly (numpy does, for a runtime feature check), which instead
    hard-errors ("Can not run test applications in this cross
    environment") unless an actual `exe_wrapper` program is configured.
    binfmt_misc on this host already runs target-arch ELFs transparently
    (verified: qemu-aarch64 is registered), so the wrapper mostly just
    needs to exec straight through — it's meson's contract that needs a
    program here, not anything the emulation itself is missing. The one
    thing it does add is QEMU_LD_PREFIX, pointed at the gcc cross
    toolchain's own sysroot: meson's *compiler* sanity check links a tiny
    test binary against that sysroot's glibc, and without QEMU_LD_PREFIX
    qemu-user falls back to searching the exec host's own filesystem for
    ld-linux-aarch64.so.1 (an amd64 Linux box has none) — an entirely
    different failure mode than the earlier "not runnable" one, but the
    same root cause of not telling qemu-user which glibc actually matches.
    """
    exe_wrapper = _write_generated_file(
        path.join(tmpdir, "meson_exe_wrapper.py"),
        _MESON_EXE_WRAPPER.format(qemu_ld_prefix=build_env.get("RULES_PY_TARGET_GCC_SYSROOT", "")),
        executable=True,
    )
    return _write_generated_file(
        path.join(tmpdir, "cross_file.ini"),
        textwrap.dedent("""\
            [binaries]
            c = '{cc}'
            cpp = '{cxx}'
            ar = '{ar}'
            strip = '{strip}'
            exe_wrapper = ['{exe_wrapper}']

            [host_machine]
            system = '{system}'
            cpu_family = '{cpu_family}'
            cpu = '{cpu}'
            endian = 'little'

            [properties]
            needs_exe_wrapper = true
            """).format(
            cc=build_env["CC"],
            cxx=build_env["CXX"],
            exe_wrapper=exe_wrapper,
            ar=build_env.get("AR", "ar"),
            strip=build_env.get("STRIP", "strip"),
            system=target_os,
            cpu_family=target_cpu,
            cpu=target_cpu,
        ),
    )


_RUST_TARGET_OS = {"linux": "unknown-linux-gnu", "darwin": "apple-darwin"}

_RUSTC_WRAPPER = """#!/usr/bin/env python3
import os
import sys

os.execv({rustc!r}, [{rustc!r}, "--sysroot", {sysroot!r}] + sys.argv[1:])
"""


def _merge_rust_sysroot(tmpdir: str, target_rustc: str, host_sysroot: str) -> str:
    """Symlink-merge the target toolchain's sysroot with the host's rust-std.

    A rules_rust cross rust_toolchain's sysroot only bundles the exec
    platform's LLVM shared libs (needed to *run* rustc), not its rust-std —
    cargo still needs a real exec-platform rust-std to compile build
    scripts/proc-macros, which are always host artifacts regardless of
    --target. rustup-based cross setups don't hit this because one rustc
    install holds every added target's std side by side; recreate that here
    by merging the two Bazel-fetched, single-target sysroots into one.
    """
    target_sysroot = path.dirname(path.dirname(target_rustc))
    merged = path.join(tmpdir, ".rust_sysroot")
    if path.exists(merged):
        return merged
    makedirs(merged)
    for entry in os.listdir(target_sysroot):
        if entry != "lib":
            os.symlink(path.join(target_sysroot, entry), path.join(merged, entry))
    merged_lib = path.join(merged, "lib")
    makedirs(merged_lib)
    for entry in os.listdir(path.join(target_sysroot, "lib")):
        if entry != "rustlib":
            os.symlink(path.join(target_sysroot, "lib", entry), path.join(merged_lib, entry))
    merged_rustlib = path.join(merged_lib, "rustlib")
    makedirs(merged_rustlib)
    host_rustlib = path.join(host_sysroot, "lib", "rustlib")
    target_rustlib = path.join(target_sysroot, "lib", "rustlib")
    overridden = set()
    for entry in os.listdir(host_rustlib):
        os.symlink(path.join(host_rustlib, entry), path.join(merged_rustlib, entry))
        overridden.add(entry)
    for entry in os.listdir(target_rustlib):
        if entry not in overridden:
            os.symlink(path.join(target_rustlib, entry), path.join(merged_rustlib, entry))
    return merged


def _configure_cargo_cross_env(build_env: Dict[str, str], tmpdir: str, target_os: str, target_cpu: str) -> None:
    """Cross env vars for maturin/setuptools-rust (Cargo-driven PyO3 builds).

    Cargo has no cross auto-detection to piggyback on the way meson-python's
    macOS ARCHFLAGS case does — a cross build always needs an explicit
    --target, and cargo has no idea which linker can actually produce a
    binary for that target unless told via CARGO_TARGET_<TRIPLE>_LINKER, so
    it falls back to $CC (the *host* driver) and fails at the link step.
    """
    os_suffix = _RUST_TARGET_OS.get(target_os, target_os)
    triple = "{}-{}".format(target_cpu, os_suffix)
    build_env["CARGO_BUILD_TARGET"] = triple
    linker_var = "CARGO_TARGET_{}_LINKER".format(triple.upper().replace("-", "_"))
    build_env[linker_var] = build_env["CC"]

    # PyO3's build script (pyo3-ffi) refuses to cross-compile without either
    # an abi3-py3* feature or an explicit target Python version — maturin
    # works around this itself (PYO3_CONFIG_FILE), but setuptools-rust just
    # shells out to plain `cargo rustc` with no PyO3-specific help at all.
    # Harmless to set even for non-PyO3 crates (simply unused).
    build_env["PYO3_CROSS_PYTHON_VERSION"] = "{}.{}".format(sys.version_info.major, sys.version_info.minor)

    host_sysroot = build_env.get("RULES_PY_RUST_HOST_SYSROOT")
    if host_sysroot:
        merged_sysroot = _merge_rust_sysroot(tmpdir, build_env["RUSTC"], host_sysroot)
        build_env["RUSTC"] = _write_generated_file(
            path.join(tmpdir, ".aspect_rules_py_rustc", "rustc"),
            _RUSTC_WRAPPER.format(rustc=build_env["RUSTC"], sysroot=merged_sysroot),
            executable=True,
        )

    # maturin's PEP 517 wrapper passes -i <sys.executable> by default so it
    # can inspect the target interpreter's ABI. In cross mode it refuses to
    # actually execute that path (it may not be host-runnable) and instead
    # name-parses it for a "pythonX.Y"-shaped basename — but our venv's
    # sys.executable is the generic "python" symlink, which fails that
    # parse. Point it at the versioned sibling instead, which the venv's
    # bin dir (already on $PATH) also provides.
    build_env["MATURIN_PEP517_ARGS"] = "--interpreter python{}.{}".format(
        sys.version_info.major,
        sys.version_info.minor,
    )


_SITECUSTOMIZE_TEMPLATE = """\
import os
import platform
import collections

_machine = {machine!r}
_sysname = {sysname!r}

os.uname = lambda: os.uname_result((_sysname, "build", "", "", _machine))

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
_platform_uname = _PlatformUname(_sysname, "build", "", "", _machine, _machine)

platform.uname = lambda: _platform_uname
platform.system = lambda: _sysname
platform.machine = lambda: _machine
platform.libc_ver = lambda *a, **k: ("", "")

# packaging.tags._linux_platforms derives its arch from sysconfig.get_platform()
# (already correctly faked via $_PYTHON_HOST_PLATFORM), not from platform.machine()
# — no patch needed there. Only the manylinux-compatibility gate below is ours to
# set, via the top-level _manylinux hook packaging._manylinux itself looks for.
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


def _generate_cross_site(tmpdir: str, target_os: str, target_cpu: str) -> str:
    """sitecustomize + _manylinux hook faking the target's runtime identity.

    sysconfig.get_platform()/_get_sysconfigdata_name() are already faked via
    env vars that CPython itself reads (_PYTHON_HOST_PLATFORM,
    _PYTHON_SYSCONFIGDATA_NAME) — no patching needed there. But some build
    backends and package setup.py scripts branch on os.uname()/
    platform.machine() directly (e.g. to pick vectorized/arch-specific code
    paths), which env vars can't reach. sitecustomize.py runs automatically
    on interpreter startup — before any backend code executes — and patches
    the already-imported os/platform modules in place. Modeled on crossenv's
    os-patch.py/platform-patch.py/_manylinux.py, minus what rules_py doesn't
    need (dual venvs, distutils.sysconfig, importlib.machinery interception).
    """
    site_dir = path.join(tmpdir, ".cross_site")
    _write_generated_file(
        path.join(site_dir, "sitecustomize.py"),
        _SITECUSTOMIZE_TEMPLATE.format(machine=target_cpu, sysname=_TITLECASE_OS.get(target_os, target_os)),
    )
    _write_generated_file(path.join(site_dir, "_manylinux.py"), _MANYLINUX_HOOK)
    return site_dir


_REQUIREMENT_NAME_RE = re.compile(r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)")


def _requirement_name(requirement: str) -> str:
    """PEP 508 requirement string -> bare package name, extras/specifiers/markers stripped."""
    match = _REQUIREMENT_NAME_RE.match(requirement)
    return match.group(1) if match else ""


def _legacy_metadata_conflicts_with_pyproject(worktree: str, pyproject_data: Optional[Dict[str, object]]) -> bool:
    setup_py = path.join(worktree, "setup.py")
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

_WHEEL_OS_MAP = {"linux": "linux", "darwin": "macosx", "windows": "win"}


def _expected_cpu_in_tag(target_os: str, target_cpu: str) -> str:
    if target_os == "darwin":
        return {"aarch64": "arm64", "x86_64": "x86_64"}.get(target_cpu, target_cpu)
    return {"x86_64": "x86_64", "aarch64": "aarch64", "x86": "i686", "arm": "armv7l"}.get(target_cpu, target_cpu)


def _validate_wheel_platform(wheel_filename: str) -> None:
    target_os = os.environ.get("RULES_PY_TARGET_OS", "")
    target_cpu = os.environ.get("RULES_PY_TARGET_CPU", "")
    if not target_os or not target_cpu:
        return

    platform_tag = wheel_filename.rsplit("-", 1)[-1].rsplit(".", 1)[0].lower()

    expected_os = _WHEEL_OS_MAP.get(target_os, target_os)
    expected_cpu = _expected_cpu_in_tag(target_os, target_cpu)

    host_os = _platform.system().lower()
    host_wheel_os = _WHEEL_OS_MAP.get(host_os, host_os)

    if target_os != host_os and host_wheel_os in platform_tag:
        print(
            "Error: wheel platform tag '{}' contains exec host OS '{}' instead of "
            "target OS '{}'. The target sysconfig override may have failed.".format(
                platform_tag, host_wheel_os, expected_os,
            ),
            file=sys.stderr,
        )
        exit(1)

    if expected_os not in platform_tag:
        print(
            "Error: wheel platform tag '{}' does not contain target OS '{}'.".format(
                platform_tag, expected_os,
            ),
            file=sys.stderr,
        )
        exit(1)

    if expected_cpu not in platform_tag:
        print(
            "Error: wheel platform tag '{}' does not contain target CPU '{}'.".format(
                platform_tag, expected_cpu,
            ),
            file=sys.stderr,
        )
        exit(1)


PARSER = ArgumentParser()
PARSER.add_argument("srcarchive")
PARSER.add_argument("outdir")
PARSER.add_argument("--monitor-memory", action="store_true")
PARSER.add_argument("--validate-anyarch", action="store_true")
PARSER.add_argument("--patch-strip", type=int, default=0, help="Strip count for patch (-p)")
PARSER.add_argument("--patch", action="append", default=[], dest="patches", help="Patch file to apply (repeatable)")
PARSER.add_argument("--execroot-marker", help="Token in env values to replace with the absolute execroot")
PARSER.add_argument("--cross", action="store_true", help="Cross-compilation mode: target platform != exec platform")
PARSER.add_argument("--target-os", default="", help="Target platform OS (linux, darwin, windows)")
PARSER.add_argument("--target-cpu", default="", help="Target platform CPU (x86_64, aarch64, ...)")
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
build_env = _compiler_env(
    tmp_root,
    opts.execroot_marker,
    cross=opts.cross,
    target_os=opts.target_os,
    target_cpu=opts.target_cpu,
)

pyproject_data = _load_pyproject_data(t)

if _legacy_metadata_conflicts_with_pyproject(t, pyproject_data):
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
    build_system = (pyproject_data or {}).get("build-system", {})
    build_backend = build_system.get("build-backend") if isinstance(build_system, dict) else None

    # meson-python has no auto-detection for a missing system BLAS/LAPACK
    # the way it does for a missing cross-file (see below) — a package that
    # needs one (numpy) has to pass its own -Dblas=none/-Dlapack=none (or
    # similar) setup-args, and needs them for a native build here too, since
    # our build venv never has a system BLAS/LAPACK either. meson-python's
    # "setup-args" config-setting is list-typed, and `build`'s -C flag
    # accumulates repeated keys into a list, so this can't collide with the
    # --cross-file argument the cross branch below adds separately.
    if build_backend == "mesonpy":
        for arg in shlex.split(build_env.get("RULES_PY_MESON_SETUP_ARGS", "")):
            cmd += ["-C", "setup-args=" + arg]

    if opts.cross:
        build_requires = build_system.get("requires", []) if isinstance(build_system, dict) else []
        if not isinstance(build_requires, list):
            build_requires = []
        # setuptools-rust has no build-backend value of its own — it's just
        # setuptools.build_meta with an extra requirement — and no --target
        # flag of its own either: it shells out to plain `cargo rustc` and
        # relies on $CARGO_BUILD_TARGET, same as maturin does once we set it.
        uses_setuptools_rust = build_backend in _SETUPTOOLS_BACKENDS and any(
            isinstance(req, str) and _requirement_name(req) == "setuptools-rust" for req in build_requires
        )
        if build_backend == "mesonpy":
            cross_file = _generate_meson_cross_file(tmp_root, build_env, opts.target_os, opts.target_cpu)
            cmd += ["-C", "setup-args=--cross-file=" + cross_file]
        elif build_backend == "scikit_build_core.build":
            toolchain = _generate_cmake_toolchain_file(tmp_root, build_env, opts.target_os, opts.target_cpu)
            cmd += ["-C", "cmake.toolchain-file=" + toolchain]
        elif (build_backend == "maturin" or uses_setuptools_rust) and build_env.get("CARGO"):
            _configure_cargo_cross_env(build_env, tmp_root, opts.target_os, opts.target_cpu)
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

if opts.cross and not inventory[0].endswith("-none-any.whl"):
    _validate_wheel_platform(inventory[0])
