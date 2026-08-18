#!/usr/bin/env python3

"""Drive a PEP 517 sdist-to-wheel build inside a Bazel action.

Unpacks the sdist, assembles a build environment that survives the backend's
chdir (compiler wrappers, absolutized toolchain paths) and — in cross mode —
fakes the target platform's identity for the backend, then runs the
pypa/build frontend. Deliberately a single self-contained script: it is the
`main` of the py_binary each sdist_build repo generates.
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
from typing import NoReturn

try:
    tomllib = importlib.import_module("tomllib")
except ModuleNotFoundError:
    tomllib = importlib.import_module("tomli")

_SETUPTOOLS_BACKENDS = (
    None,
    "setuptools.build_meta",
    "setuptools.build_meta:__legacy__",
)


def _die(message: str) -> NoReturn:
    print(message, file=sys.stderr)
    sys.exit(1)


# Clang-only DWARF flag some Bazel toolchains inject; stripped by the
# wrappers because non-clang drivers reject it.
_DEBUG_FLAG = "-fdebug-default-version=4"

# Forces the static libstdc++ archive when the configured C++ tool is a
# plain C driver ("gcc", "clang"): only the "g++"/"clang++" argv[0] spec
# adds the implicit libstdc++ link, so under such toolchains (e.g.
# gcc_toolchain, whose cpp tool_path is "gcc") C++ extensions can build and
# even import (borrowing symbols another loaded .so pulled in) yet fail at
# runtime. Static, because a hermetic toolchain's libstdc++.so won't exist
# on the deployment target. Real C++ drivers keep their own (dynamic)
# stdlib link untouched. GNU-ld-only syntax: skipped on Darwin, where
# clang++ links libc++ implicitly.
_STATIC_LIBSTDCXX_FLAGS = ("-Wl,-Bstatic", "-lstdc++", "-Wl,-Bdynamic")


def _static_libstdcxx_flags(compiler_path: str, is_cxx: bool, is_darwin: bool) -> list[str]:
    if is_cxx and not is_darwin and not path.basename(compiler_path).endswith("++"):
        return list(_STATIC_LIBSTDCXX_FLAGS)
    return []

_COMPILER_WRAPPER = """#!/usr/bin/env python3
import os
import sys

filtered_args = [arg for arg in sys.argv[1:] if arg != "{debug_flag}"]
is_cxx = {is_cxx!r}
is_darwin = {is_darwin!r}
# Same non-link detection as the cross wrapper: compiles, preprocessing,
# and compiler-introspection probes must not receive link-only flags.
is_link = True
for _arg in filtered_args:
    if _arg in ("-c", "-E", "-S", "-fsyntax-only", "--version", "-dumpmachine", "-dumpversion", "-###") or _arg.startswith("-print-"):
        is_link = False
        break
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
lld_path = {lld_path!r}
debug_flag = {debug_flag!r}
is_cxx = {is_cxx!r}
is_darwin = {is_darwin!r}
static_libstdcxx_flags = {static_libstdcxx_flags!r}
exe_link_flags = {exe_link_flags!r}
static_runtime_archives = {static_runtime_archives!r}

# Not a link if compiling/preprocessing (-c/-E/-S/-fsyntax-only) or if this
# is a compiler-introspection probe (meson runs "-E -v -", "-print-*",
# "--version" through us): appending link inputs there is at best noise and
# at worst catastrophic — "-E" *preprocesses* positional inputs, so an
# appended static archive becomes megabytes of binary on stdout that
# meson then strictly utf-8 decodes.
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

# Standalone (non-shared) executables built here are never the wheel
# deliverable — only throwaway feature probes (meson sanity checks,
# cc.run()) executed under QEMU, where dynamically-linked target-arch PIE
# binaries hit a real qemu-user/glibc startup bug ("Inconsistency detected
# by ld.so: ... DT_VERSYM"), reproducible with a single-toolchain
# hello-world. "-static" sidesteps ld.so entirely; the .so deliverables
# always link shared and load via dlopen's unrelated path. Mutually
# exclusive with the static-libstdc++ trick: its trailing "-Wl,-Bdynamic"
# would undo a bare "-static" for driver-appended libs (libc included).
# Shared-link spellings: "-shared" (ELF), "-bundle"/"-dynamiclib" (ld64).
# Scan pre-filter args: the darwin spellings are host-leak-dropped from
# `filtered` when the target is not darwin.
is_shared = any(a in ("-shared", "-bundle", "-dynamiclib") for a in args)
if is_darwin and is_link and is_shared:
    # Extension modules leave _Py* unresolved until dlopen; ld64 errors on
    # them by default (ELF linkers don't), so mirror CPython's own LDSHARED
    # unless the backend already passed it (kept as "-undefined
    # dynamic_lookup" or the combined -Wl spelling). Takes precedence over
    # the exe_link_flags branch: target identity beats toolchain plumbing.
    if "dynamic_lookup" not in filtered and "-Wl,-undefined,dynamic_lookup" not in filtered:
        filtered.append("-Wl,-undefined,dynamic_lookup")
elif is_link and exe_link_flags:
    # LLVM-style toolchain (see the "-nostdlib++" detection in
    # build_helper): clang only reaches its crt objects and glibc/libc++
    # archives through the link action's -B/-L/--sysroot flags, and not
    # every caller threads $LDSHARED through (rustc invokes this wrapper as
    # "-C linker", meson links probes bare) — bake the flags into every
    # link; duplicates are harmless to clang.
    # rustc hardcodes "-lgcc_s" on *-linux-gnu but this toolchain ships no
    # libgcc; its unwinder comes from the static runtime archives below
    # (or, without them, from folding in "-lunwind" — cargo-zigbuild's
    # trick, same ABI surface).
    if static_runtime_archives and not is_darwin:
        filtered = [a for a in filtered if a != "-lgcc_s"]
    else:
        filtered = ["-lunwind" if a == "-lgcc_s" else a for a in filtered]
    filtered.extend(exe_link_flags)
    if static_runtime_archives and not is_darwin:
        # The toolchain's C++/unwind runtime (libc++.a, libc++abi.a,
        # libunwind.a) travels as toolchain inputs, never as link flags —
        # link the archives explicitly, in dependency order, after every
        # object. Archive semantics make this safe on pure-C links: unused
        # members are simply not pulled.
        filtered.extend(static_runtime_archives)
    elif is_cxx:
        # No implicit C++ stdlib under -nostdlib++; statically embed
        # libc++ so the produced .so has no host-libstdc++ dependency
        # (only static archives exist on the toolchain's search path).
        filtered.extend(["-lc++", "-lc++abi"])
elif is_link and not is_shared and not is_darwin:
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


def _darwin_sysroot() -> str | None:
    """Return the macOS SDK path, or None if unavailable."""
    if _platform.system() != "Darwin":
        return None
    try:
        return check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    except Exception:
        return None


def _xcode_developer_dir() -> str | None:
    """Return the active Xcode Developer directory, or None if unavailable."""
    try:
        return check_output(["xcode-select", "-p"], text=True).strip()
    except Exception:
        return None


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


def _absolutize_path(value: str) -> str:
    """Make a relative path absolute: execroot-relative toolchain paths stop
    resolving once the PEP 517 backend chdirs into the unpacked sdist."""
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
    sysroot: str | None = None,
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
            static_libstdcxx_flags=_static_libstdcxx_flags(compiler_path, is_cxx, is_darwin),
        ),
        executable=True,
    )


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


def _find_lld(compiler_path: str) -> str | None:
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
    lld_path: str | None = None,
    is_cxx: bool = False,
    is_darwin: bool = False,
    exe_link_flags: list[str] | None = None,
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
            lld_path=lld_path,
            debug_flag=_DEBUG_FLAG,
            is_cxx=is_cxx,
            is_darwin=is_darwin,
            static_libstdcxx_flags=list(_STATIC_LIBSTDCXX_FLAGS),
            exe_link_flags=list(exe_link_flags or []),
            static_runtime_archives=list(static_runtime_archives or []),
        ),
        executable=True,
    )


_AR_LIBTOOL_WRAPPER = """#!/usr/bin/env python3
import os
import sys

libtool = {libtool!r}
args = sys.argv[1:]

# Already libtool-style ("-static ...") or a tool probe ("--version", "-V"):
# hand through untouched.
if not args or args[0].startswith("-"):
    os.execv(libtool, [libtool] + args)

# ar-style "<ops> <archive> <members...>" (meson "csr", CMake "qc",
# distutils "rcs"). libtool -static always rewrites the whole symbol-tabled
# archive, so create/replace/append modifiers all collapse to the same call.
archive = args[1]
members = args[2:]
os.execv(libtool, [libtool, "-static", "-o", archive] + members)
"""


def _make_ar_libtool_wrapper(tmpdir: str, libtool_path: str) -> str:
    wrapper = path.join(tmpdir, ".aspect_rules_py_compilers", "ar")
    return _write_generated_file(
        wrapper,
        _AR_LIBTOOL_WRAPPER.format(libtool=libtool_path),
        executable=True,
    )


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
    execroot_marker: str | None = None,
    cross: bool = False,
    target_os: str = "",
    target_cpu: str = "",
) -> dict[str, str]:
    env = dict(os.environ)
    if execroot_marker:
        execroot = os.getcwd()
        env = {key: value.replace(execroot_marker, execroot) for key, value in env.items()}
    # The helper's own launcher exported this runfiles identity; nested Bazel
    # executables launched by package code would trust it over their adjacent
    # runfiles, so strip it before any package code runs.
    for key in (
        "JAVA_RUNFILES",
        "RUNFILES_DIR",
        "RUNFILES_MANIFEST_FILE",
        "RUNFILES_MANIFEST_ONLY",
    ):
        env.pop(key, None)
    # Some build deps (maturin) ship plain wheel-data scripts under
    # <whl_install output>/bin, which venv assembly never merges (it only
    # merges lib/site-packages) — so they land on neither sys.path nor PATH.
    # They are still real runfiles; walk the runfiles roots for whl_install
    # bin/ dirs and put those on PATH.
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

    # PBS interpreters bake their original build-time prefix into sysconfig's
    # LIBDIR ("/install/lib", nonexistent after relocation), so anything that
    # links libpythonX.Y (meson's Cython sanity check) fails. The
    # interpreter's own pkg-config file resolves relative to itself
    # (${pcfiledir}/../..) — point PKG_CONFIG_PATH at it instead.
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
        for key in ("CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDSHAREDFLAGS"):
            if env.get(key):
                env[key] = _absolutize_sysroot_flags(env[key])

        wrapper_flags = _get_wrapper_flags(env.get("CFLAGS", ""))
        lld_path = _find_lld(cc_path)

        # The -nostdlib++ toolchain's C++/unwind runtime archives, extracted
        # by cc_layer.bzl from static_runtime_lib (they never appear in the
        # link-action flags). Ordered for single-pass archive resolution:
        # libc++ pulls from libc++abi, which pulls from libunwind.
        static_runtime = [
            _absolutize_path(p)
            for p in env.pop("RULES_PY_CXX_STATIC_RUNTIME", "").split(":")
            if p
        ]
        runtime_rank = {"libc++.a": 0, "libc++abi.a": 1, "libunwind.a": 2}
        static_runtime.sort(key=lambda p: runtime_rank.get(path.basename(p), 3))

        # An LLVM-style toolchain (BCR `llvm` module) reaches its crt objects
        # and runtime archives only through the link action's flags; detect it
        # by its "-nostdlib++" marker and bake those flags (sans "-shared")
        # into the wrappers for probe-executable links. gcc_toolchain's driver
        # is self-contained — it gets an empty list and keeps its "-static".
        ldshared_flag_list = env.get("LDSHAREDFLAGS", "").split()
        exe_link_flags = (
            [f for f in ldshared_flag_list if f != "-shared"] if "-nostdlib++" in ldshared_flag_list else []
        )

        cc = _make_cross_compiler_wrapper(tmpdir, "cc", cc_path, wrapper_flags, lld_path, is_darwin=is_darwin, exe_link_flags=exe_link_flags, static_runtime_archives=static_runtime)
        cxx = _make_cross_compiler_wrapper(tmpdir, "c++", cxx_path, wrapper_flags, lld_path, is_cxx=True, is_darwin=is_darwin, exe_link_flags=exe_link_flags, static_runtime_archives=static_runtime)

        # gcc_toolchain layout (<root>/xbin/gcc, <root>/sysroot/...): a
        # target-arch binary needs THIS toolchain's glibc/loader to run.
        # Consumed only by meson's exe_wrapper (_generate_meson_cross_file).
        target_gcc_sysroot = path.join(path.dirname(path.dirname(cc_path)), "sysroot")
        if not is_darwin and path.isdir(target_gcc_sysroot):
            env["RULES_PY_TARGET_GCC_SYSROOT"] = target_gcc_sysroot

        # apple_support's wrapped_clang hard-fails without DEVELOPER_DIR /
        # SDKROOT; Bazel injects them only into actions with Xcode execution
        # requirements, which this PEP 517 action is not.
        if is_darwin and _platform.system() == "Darwin":
            if "DEVELOPER_DIR" not in env:
                developer_dir = _xcode_developer_dir()
                if developer_dir:
                    env["DEVELOPER_DIR"] = developer_dir
            if sysroot and "SDKROOT" not in env:
                env["SDKROOT"] = sysroot
    else:
        cc = _make_compiler_wrapper(tmpdir, "cc", cc_path, sysroot, is_darwin=is_darwin)
        cxx = _make_compiler_wrapper(tmpdir, "c++", cxx_path, sysroot, is_cxx=True, is_darwin=is_darwin)

    env.setdefault("CC", cc)
    env.setdefault("CXX", cxx)

    if cross:
        ldshared_flags = env.get("LDSHAREDFLAGS", "")
        env["LDSHARED"] = cc + (" " + ldshared_flags if ldshared_flags else "")
        env["LDCXXSHARED"] = cxx + (" " + ldshared_flags if ldshared_flags else "")

        deployment_target = None
        target_sysconfig = env.get("RULES_PY_TARGET_SYSCONFIGDATA")
        if target_sysconfig and path.exists(target_sysconfig):
            sysconfig_dir = path.join(tmpdir, ".target_sysconfig")
            makedirs(sysconfig_dir, exist_ok=True)
            shutil.copy(target_sysconfig, sysconfig_dir)
            module_name = path.basename(target_sysconfig)[:-3]
            env["_PYTHON_SYSCONFIGDATA_NAME"] = module_name
            env["PYTHONPATH"] = sysconfig_dir + pathsep + env.get("PYTHONPATH", "")

            # The analysis-time _PYTHON_HOST_PLATFORM (rule.bzl) can only
            # guess macosx-11.0; the target interpreter's sysconfig knows the
            # real deployment version its wheel tags must carry. distutils'
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

    # MPI builds (mpi4py) consult $MPICC before PATH; only set it when a real
    # mpicc exists, wrapped to keep the debug-flag stripping.
    mpicc_path = shutil.which("mpicc", path=env["PATH"])
    if mpicc_path:
        env.setdefault("MPICC", _make_compiler_wrapper(tmpdir, "mpicc", mpicc_path, sysroot))

    # $AR consumers (meson, distutils, CMake) all invoke it with ar-style
    # args, but the llvm toolchain's cpp_link_static_library tool on a darwin
    # exec host is llvm-libtool-darwin, which only accepts libtool-style
    # `-static -o`. Prefer the sibling llvm-ar (symbol-table'd archives
    # satisfy ld64 and ELF linkers alike), but the sandbox only mounts the
    # toolchain's declared tool files — llvm-ar is usually not among them —
    # so fall back to a wrapper that translates ar-style argv to libtool's.
    ar_path = env.get("AR", "")
    if path.basename(ar_path) == "llvm-libtool-darwin":
        llvm_ar = path.join(path.dirname(ar_path), "llvm-ar")
        if path.exists(llvm_ar):
            env["AR"] = llvm_ar
        else:
            env["AR"] = _make_ar_libtool_wrapper(tmpdir, ar_path)
    env.setdefault("AR", "ar")

    for key, wrapper in [
        ("CC", cc),
        ("CXX", cxx),
        ("CPP", cc),
        ("LDSHARED", cc),
        ("LDCXXSHARED", cxx),
    ]:
        _override_tool(env, key, wrapper)

    # maturin and setuptools-rust locate cargo via shutil.which, not $CARGO —
    # without it on PATH they auto-install a Rust toolchain (puccinialin).
    cargo_path = env.get("CARGO")
    if cargo_path:
        env["PATH"] = pathsep.join([path.dirname(cargo_path), env.get("PATH", defpath)])

        # Cargo's default $CARGO_HOME (~/.cargo) is unwritable in the sandbox.
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


def _load_pyproject_data(worktree: str) -> dict[str, object] | None:
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
_SYS_PLATFORM = {"linux": "linux", "darwin": "darwin", "windows": "win32"}


def _generate_cmake_toolchain_file(
    tmpdir: str,
    build_env: dict[str, str],
    target_os: str,
    target_cpu: str,
) -> str:
    """Cross toolchain file for scikit-build-core/CMake.

    scikit-build-core only auto-detects macOS ARCHFLAGS cross builds; a
    Linux-arch cross build configures as native — it compiles fine off
    $CC/$CXX but find_program picks the host `strip`, which rejects the
    foreign-arch .so. CMAKE_SYSTEM_NAME also enables real
    CMAKE_CROSSCOMPILING mode.
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
    `needs_exe_wrapper` alone only covers meson's own checks — projects
    calling `cc.run()` directly (numpy) hard-error unless a real
    `exe_wrapper` program exists. binfmt_misc+qemu-user already runs
    target-arch ELFs transparently, so the wrapper just execs through; what
    it adds is QEMU_LD_PREFIX pointed at the cross toolchain's sysroot,
    without which qemu-user searches the exec host for the target's
    ld-linux/glibc and finds none.
    """
    # The wrapper is only offered when the emulated binary can actually
    # resolve its dynamic interpreter: binfmt+qemu need QEMU_LD_PREFIX to
    # locate the target's ld.so/glibc, and only the gcc_toolchain layout
    # hands us that sysroot. Everywhere else (darwin hosts can't execute
    # ELF at all; the llvm toolchain's empty-sysroot layout gives qemu no
    # loader prefix) meson gets needs_exe_wrapper=true with NO exe_wrapper:
    # it skips its own sanity runs and cc.run() callers get meson's
    # explicit cross-environment error — an honest limitation.
    exe_wrapper_line = ""
    if _platform.system() == "Linux" and build_env.get("RULES_PY_TARGET_GCC_SYSROOT"):
        exe_wrapper = _write_generated_file(
            path.join(tmpdir, "meson_exe_wrapper.py"),
            _MESON_EXE_WRAPPER.format(qemu_ld_prefix=build_env.get("RULES_PY_TARGET_GCC_SYSROOT", "")),
            executable=True,
        )
        exe_wrapper_line = "exe_wrapper = ['{}']\n".format(exe_wrapper)

    # numpy's documented cross recipe: its meson.build reads this external
    # property and only falls back to a cc.run() probe when it is absent —
    # which hard-errors wherever no exe_wrapper exists (any darwin→linux
    # cross). The value is an ABI constant of (os, cpu, libc), so bake it in
    # rather than making every consumer rediscover numpy gh-23972.
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
            {exe_wrapper_line}
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
            exe_wrapper_line=exe_wrapper_line,
            longdouble_line=longdouble_line,
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

    A cross rust_toolchain's sysroot has no exec-platform rust-std, but
    cargo needs one to compile build scripts/proc-macros (always host
    artifacts regardless of --target). rustup holds every target's std side
    by side in one install; recreate that by merging the two Bazel-fetched
    single-target sysroots.
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


def _configure_cargo_cross_env(build_env: dict[str, str], tmpdir: str, target_os: str, target_cpu: str) -> None:
    """Cross env vars for maturin/setuptools-rust (Cargo-driven PyO3 builds).

    Cargo has no cross auto-detection: it needs an explicit target triple,
    and without CARGO_TARGET_<TRIPLE>_LINKER it links with the host driver
    and fails.
    """
    os_suffix = _RUST_TARGET_OS.get(target_os, target_os)
    triple = "{}-{}".format(target_cpu, os_suffix)
    build_env["CARGO_BUILD_TARGET"] = triple
    linker_var = "CARGO_TARGET_{}_LINKER".format(triple.upper().replace("-", "_"))
    build_env[linker_var] = build_env["CC"]

    # pyo3-ffi refuses to cross-compile without an explicit target Python
    # version; maturin works around it itself, setuptools-rust does not.
    # Unused (harmless) for non-PyO3 crates.
    build_env["PYO3_CROSS_PYTHON_VERSION"] = "{}.{}".format(sys.version_info.major, sys.version_info.minor)

    host_sysroot = build_env.get("RULES_PY_RUST_HOST_SYSROOT")
    if host_sysroot:
        merged_sysroot = _merge_rust_sysroot(tmpdir, build_env["RUSTC"], host_sysroot)
        build_env["RUSTC"] = _write_generated_file(
            path.join(tmpdir, ".aspect_rules_py_rustc", "rustc"),
            _RUSTC_WRAPPER.format(rustc=build_env["RUSTC"], sysroot=merged_sysroot),
            executable=True,
        )

    # In cross mode maturin name-parses its -i interpreter argument for a
    # "pythonX.Y"-shaped basename instead of executing it; our venv's
    # sys.executable is the generic "python" symlink, which fails that parse
    # — point it at the versioned sibling the venv also provides.
    build_env["MATURIN_PEP517_ARGS"] = "--interpreter python{}.{}".format(
        sys.version_info.major,
        sys.version_info.minor,
    )


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
    _write_generated_file(
        path.join(site_dir, "sitecustomize.py"),
        _SITECUSTOMIZE_TEMPLATE.format(
            machine=target_cpu,
            sysname=_TITLECASE_OS.get(target_os, target_os),
            release=release,
            sys_platform=_SYS_PLATFORM.get(target_os, target_os),
        ),
    )
    _write_generated_file(path.join(site_dir, "_manylinux.py"), _MANYLINUX_HOOK)
    return site_dir


_REQUIREMENT_NAME_RE = re.compile(r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)")


def _requirement_name(requirement: str) -> str:
    """PEP 508 requirement string -> bare package name, extras/specifiers/markers stripped."""
    match = _REQUIREMENT_NAME_RE.match(requirement)
    return match.group(1) if match else ""


def _legacy_metadata_conflicts_with_pyproject(worktree: str, pyproject_data: dict[str, object] | None) -> bool:
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

_WHEEL_OS_MAP = {"linux": "linux", "darwin": "macosx", "windows": "win"}


def _expected_cpu_in_tag(target_os: str, target_cpu: str) -> str:
    if target_os == "darwin" and target_cpu == "aarch64":
        return "arm64"
    return {"x86": "i686", "arm": "armv7l"}.get(target_cpu, target_cpu)


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
        _die(
            "Error: wheel platform tag '{}' contains exec host OS '{}' instead of "
            "target OS '{}'. The target sysconfig override may have failed.".format(
                platform_tag, host_wheel_os, expected_os,
            )
        )
    if expected_os not in platform_tag:
        _die("Error: wheel platform tag '{}' does not contain target OS '{}'.".format(platform_tag, expected_os))
    if expected_cpu not in platform_tag:
        _die("Error: wheel platform tag '{}' does not contain target CPU '{}'.".format(platform_tag, expected_cpu))


PARSER = ArgumentParser()
PARSER.add_argument("srcarchive")
PARSER.add_argument("output", help="Path the single built wheel is written to")
PARSER.add_argument("--monitor-memory", action="store_true")
PARSER.add_argument("--validate-anyarch", action="store_true")
PARSER.add_argument("--patch-strip", type=int, default=0, help="Strip count for patch (-p)")
PARSER.add_argument("--patch", action="append", default=[], dest="patches", help="Patch file to apply (repeatable)")
PARSER.add_argument("--execroot-marker", help="Token in env values to replace with the absolute execroot")
PARSER.add_argument("--cross", action="store_true", help="Cross-compilation mode: target platform != exec platform")
PARSER.add_argument("--target-os", default="", help="Target platform OS (linux, darwin, windows)")
PARSER.add_argument("--target-cpu", default="", help="Target platform CPU (x86_64, aarch64, ...)")
opts, _ = PARSER.parse_known_args()

tmp_root = path.abspath(opts.output) + ".tmp"
# Sandboxed/remote actions get a fresh root each run, but a failed run under
# --spawn_strategy=standalone leaves tmp_root behind and would mask the real
# error with FileExistsError on retry — reclaim our own scratch dir instead.
if path.isdir(tmp_root):
    shutil.rmtree(tmp_root)
makedirs(tmp_root)

t = path.join(tmp_root, "worktree")

shutil.unpack_archive(opts.srcarchive, t)

# unpack_archive nests the sdist's own top-level directory; follow it.
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
            _die("Error: failed to apply patch {} (patch exited {}).".format(abs_patch, exc.returncode))


# Backends take an output directory, not a file: build into a scratch dir.
outdir = path.join(tmp_root, "dist")
makedirs(outdir)

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

    # Packages needing -D setup-args (numpy's -Dblas=none — the hermetic
    # venv has no system BLAS in native mode either) pass them via this env
    # var. `build`'s -C accumulates repeated keys, so it can't collide with
    # the --cross-file the cross branch adds separately.
    if build_backend == "mesonpy":
        for arg in shlex.split(build_env.get("RULES_PY_MESON_SETUP_ARGS", "")):
            cmd += ["-C", "setup-args=" + arg]

    if opts.cross:
        build_requires = build_system.get("requires", []) if isinstance(build_system, dict) else []
        if not isinstance(build_requires, list):
            build_requires = []
        # setuptools-rust has no build-backend value of its own (it's
        # setuptools.build_meta plus a requirement) and relies on
        # $CARGO_BUILD_TARGET, same as maturin.
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
    # raise, not _die(): ty doesn't narrow NoReturn in module-level flow and
    # would flag `cmd` below as possibly unbound.
    raise SystemExit("Error: Unable to detect build command! Neither pyproject.toml nor setup.py found!")

with TemporaryFile(mode="w+") as build_log:
    try:
        if opts.monitor_memory:
            # Lazy: the dependency exists only when the wheel opts in.
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
        _die("Error: Build failed!\nSee {} for the sandbox".format(t))

inventory = listdir(outdir)

if len(inventory) != 1:
    _die("Error: Expected exactly one built wheel, found {}!\nSee {} for the sandbox".format(len(inventory), t))

if opts.validate_anyarch and not inventory[0].endswith("-none-any.whl"):
    _die("Error: Target was anyarch but built a none-any wheel!\nSee {} for the sandbox".format(t))

if opts.cross and not inventory[0].endswith("-none-any.whl"):
    _validate_wheel_platform(inventory[0])

os.replace(path.join(outdir, inventory[0]), path.abspath(opts.output))
