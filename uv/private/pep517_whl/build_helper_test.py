"""Tests for build_helper.py env path handling.

Reproduces: the PEP 517 build backend is launched with cwd inside the
unpacked sdist worktree, so Bazel/toolchain execroot-relative paths in the
environment (tool binaries, -I/-L include/library flags, JAVA_HOME, ...)
no longer resolve for native build hooks (setup.py, meson, cmake) unless
they are absolutized while cwd is still the execroot.
"""

import os
import sys
import tempfile
import types

_HELPER_SRC = os.path.join(os.path.dirname(__file__), "build_helper.py")

# build_helper.py is a script — its module-level body unpacks an sdist and
# runs a build — so it can't be imported. Exec just the prefix holding the
# imports, constants, and function definitions.
_SCRIPT_BODY_MARKER = "PARSER = ArgumentParser()"


def _load_helper():
    with open(_HELPER_SRC) as f:
        src = f.read()
    assert _SCRIPT_BODY_MARKER in src, "script body marker moved; update the test"
    mod = types.ModuleType("build_helper")
    exec(compile(src[: src.index(_SCRIPT_BODY_MARKER)], _HELPER_SRC, "exec"), mod.__dict__)
    return mod


_helper = _load_helper()
_absolutize_env_paths = _helper._absolutize_env_paths
_compiler_env = _helper._compiler_env


def _make_execroot():
    """Create a fake action execroot with toolchain-ish files plus a
    sibling "worktree" dir standing in for the unpacked sdist.

    Returns (execroot, worktree).
    """
    # realpath: on macOS mkdtemp returns /var/... (a symlink to /private/var)
    # but abspath in the helper resolves through getcwd(), which is real.
    root = os.path.realpath(tempfile.mkdtemp())
    execroot = os.path.join(root, "execroot")
    worktree = os.path.join(root, "worktree")
    for d in (
        os.path.join(execroot, "external", "tc", "bin"),
        os.path.join(execroot, "external", "tc", "include"),
        os.path.join(execroot, "external", "tc", "lib"),
        os.path.join(execroot, "external", "jdk", "bin"),
        worktree,
    ):
        os.makedirs(d)
    for f in (
        os.path.join(execroot, "external", "tc", "bin", "cc"),
        os.path.join(execroot, "external", "tc", "bin", "ar"),
        os.path.join(execroot, "external", "jdk", "bin", "java"),
    ):
        with open(f, "w") as fh:
            fh.write("#!/bin/sh\n")
    return execroot, worktree


def _absolutize_from(execroot, env):
    """Run _absolutize_env_paths with cwd at the execroot, like the helper."""
    prev = os.getcwd()
    os.chdir(execroot)
    try:
        _absolutize_env_paths(env)
    finally:
        os.chdir(prev)
    return env


def test_relative_tool_paths_resolve_after_cwd_change():
    execroot, worktree = _make_execroot()
    env = {
        "AR": "external/tc/bin/ar",
        "JAVA_HOME": "external/jdk",
        "JAVA": "external/jdk/bin/java",
    }

    # The repro: from the build backend's cwd (the unpacked worktree) the
    # execroot-relative paths don't resolve.
    prev = os.getcwd()
    os.chdir(worktree)
    try:
        assert not os.path.exists(env["AR"])
        assert not os.path.exists(env["JAVA_HOME"])

        _absolutize_from(execroot, env)

        # The fix: absolutized while cwd was the execroot, they now resolve
        # regardless of the backend's cwd.
        for key in env:
            assert os.path.isabs(env[key]), f"{key} not absolute: {env[key]}"
            assert os.path.exists(env[key]), f"{key} unresolvable: {env[key]}"
    finally:
        os.chdir(prev)


def test_attached_include_and_lib_flags():
    execroot, _ = _make_execroot()
    env = {
        "CFLAGS": "-Iexternal/tc/include -DFOO=1 -O2",
        "LDFLAGS": "-Lexternal/tc/lib -lz",
    }
    _absolutize_from(execroot, env)
    assert env["CFLAGS"] == "-I{}/external/tc/include -DFOO=1 -O2".format(execroot)
    assert env["LDFLAGS"] == "-L{}/external/tc/lib -lz".format(execroot)


def test_detached_path_flags():
    execroot, _ = _make_execroot()
    env = {
        "CPPFLAGS": "-isystem external/tc/include -iquote external/tc/include",
        "CXXFLAGS": "--sysroot external/tc -Wall",
        "EXTRA": "--sysroot=external/tc",
    }
    _absolutize_from(execroot, env)
    assert env["CPPFLAGS"] == "-isystem {0}/external/tc/include -iquote {0}/external/tc/include".format(execroot)
    assert env["CXXFLAGS"] == "--sysroot {}/external/tc -Wall".format(execroot)
    assert env["EXTRA"] == "--sysroot={}/external/tc".format(execroot)


def test_pathsep_lists():
    execroot, _ = _make_execroot()
    env = {
        "CPATH": os.pathsep.join(["external/tc/include", "/usr/include"]),
        "LIBRARY_PATH": os.pathsep.join(["external/tc/lib", "external/missing/lib"]),
    }
    _absolutize_from(execroot, env)
    assert env["CPATH"] == os.pathsep.join(
        [os.path.join(execroot, "external/tc/include"), "/usr/include"]
    )
    # Nonexistent entries are left alone.
    assert env["LIBRARY_PATH"] == os.pathsep.join(
        [os.path.join(execroot, "external/tc/lib"), "external/missing/lib"]
    )


def test_compiler_with_trailing_flags():
    execroot, _ = _make_execroot()
    env = {"CC": "external/tc/bin/cc --target=x86_64-unknown-linux-gnu"}
    _absolutize_from(execroot, env)
    assert env["CC"] == "{}/external/tc/bin/cc --target=x86_64-unknown-linux-gnu".format(execroot)


def test_non_paths_untouched():
    execroot, _ = _make_execroot()
    env = {
        "PYTHONHASHSEED": "0",
        "AR": "ar",  # bare command name, resolved via PATH
        "CFLAGS": "-O2 -Wall",
        "CC": "external/missing/cc",  # nonexistent stays as-is
        "ABS": "/usr/bin/cc",
        "EMPTY": "",
    }
    expected = dict(env)
    _absolutize_from(execroot, env)
    assert env == expected, f"unexpected rewrites: {env}"


def test_compiler_env_absolutizes_inherited_environ():
    """_compiler_env must apply the rewrite to the inherited os.environ."""
    execroot, worktree = _make_execroot()
    tmpdir = tempfile.mkdtemp()
    saved = {k: os.environ.get(k) for k in ("AR", "JAVA_HOME", "CC", "CXX", "CPP", "LDSHARED", "LDCXXSHARED")}
    prev = os.getcwd()
    os.chdir(execroot)
    try:
        os.environ["AR"] = "external/tc/bin/ar"
        os.environ["JAVA_HOME"] = "external/jdk"
        os.environ["CC"] = "external/tc/bin/cc"
        for k in ("CXX", "CPP", "LDSHARED", "LDCXXSHARED"):
            os.environ.pop(k, None)

        env = _compiler_env(tmpdir)
    finally:
        os.chdir(prev)
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    os.chdir(worktree)
    try:
        assert env["AR"] == os.path.join(execroot, "external/tc/bin/ar")
        assert env["JAVA_HOME"] == os.path.join(execroot, "external/jdk")
        # CC is re-pointed at a wrapper which execv's the absolute compiler.
        assert os.path.isabs(env["CC"]) and os.path.exists(env["CC"])
        with open(env["CC"]) as f:
            assert os.path.join(execroot, "external/tc/bin/cc") in f.read()
    finally:
        os.chdir(prev)


if __name__ == "__main__":
    failures = []
    test_fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in test_fns:
        try:
            fn()
            print(f"  PASS  {fn.__name__}")
        except Exception as e:
            print(f"  FAIL  {fn.__name__}: {e}")
            failures.append(fn.__name__)

    total = len(test_fns)
    passed = total - len(failures)
    print(f"\n{passed} passed, {len(failures)} failed (of {total})")
    if failures:
        print(f"Failures: {', '.join(failures)}")
        sys.exit(1)
