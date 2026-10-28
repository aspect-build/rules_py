"""Tests for repository.bzl BUILD generation."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//py/private/interpreter:exclude_feature.bzl", "INTERPRETER_FEATURES")
load("//py/private/interpreter:repository.bzl", "repository_testlib")

_PYCACHE_EXCLUDE = 'exclude = ["**/__pycache__/*.pyc*"]'

def _feature_filegroups_exclude_pycache_test_impl(ctx):
    env = unittest.begin(ctx)

    targets, excludes = repository_testlib.feature_filegroups("lib/python3.13", False)

    # One glob per feature, and every one of them ignores bytecode: the
    # distribution ships none, so a pyc under a feature directory was written
    # after fetch and must not become an input of the interpreter filegroups.
    globs = [line for line in targets.splitlines() if "srcs = glob(" in line]
    asserts.equals(env, len(INTERPRETER_FEATURES), len(globs))
    for line in globs:
        asserts.true(env, _PYCACHE_EXCLUDE in line, line)

    # The feature patterns are still carved out of _core.
    asserts.true(env, "lib/python3.13/pydoc_data/**" in excludes)

    # Windows generates no feature filegroups.
    asserts.equals(env, ("", []), repository_testlib.feature_filegroups("lib/python3.13", True))

    return unittest.end(env)

feature_filegroups_exclude_pycache_test = unittest.make(_feature_filegroups_exclude_pycache_test_impl)

def _build_file(abi_flags, is_macos = False, is_windows = False):
    return repository_testlib.build_file_content(
        major = "3",
        minor = "14",
        micro = "0",
        python_bin = "python.exe" if is_windows else "bin/python3",
        is_macos = is_macos,
        is_windows = is_windows,
        abi_flags = abi_flags,
        releaselevel = "final",
        serial = "0",
    )

def _freethreaded_stdlib_excludes_test_impl(ctx):
    env = unittest.begin(ctx)

    # A free-threaded build's standard library is lib/python3.14t, so the
    # test-suite and feature patterns must name that directory, or CPython's
    # own tests and every optional feature stay in _core.
    content = _build_file("t")
    for pattern in [
        "lib/python3.14t/**/test/**",
        "lib/python3.14t/**/tests/**",
        "lib/python3.14t/pydoc_data/**",
        "lib/python3.14t/tkinter/**",
    ]:
        asserts.true(env, repr(pattern) in content, pattern)
    asserts.false(env, "lib/python3.14/" in content)

    # Only the free-threading flag names the stdlib directory: a debug
    # build's is lib/python3.14 and a free-threaded debug build's is
    # lib/python3.14t.
    for abi_flags, stdlib in [("", "lib/python3.14"), ("d", "lib/python3.14"), ("td", "lib/python3.14t")]:
        content = _build_file(abi_flags)
        asserts.true(env, repr(stdlib + "/**/test/**") in content, abi_flags)
        asserts.true(env, repr(stdlib + "/pydoc_data/**") in content, abi_flags)
        asserts.false(env, "lib/python3.14d" in content, abi_flags)
        asserts.false(env, "lib/python3.14td" in content, abi_flags)
        other = "lib/python3.14/" if stdlib.endswith("t") else "lib/python3.14t/"
        asserts.false(env, other in content, abi_flags)

    return unittest.end(env)

freethreaded_stdlib_excludes_test = unittest.make(_freethreaded_stdlib_excludes_test_impl)

def _python_headers_gil_disabled_test_impl(ctx):
    env = unittest.begin(ctx)

    # Windows has one pyconfig.h for both builds, so only the free-threaded
    # Windows headers define Py_GIL_DISABLED themselves; the free-threaded
    # pyconfig.h defines it on Linux and macOS.
    for abi_flags, is_macos, is_windows, defined in [
        ("t", False, True, True),
        ("td", False, True, True),
        ("", False, True, False),
        ("d", False, True, False),
        ("t", False, False, False),
        ("t", True, False, False),
    ]:
        case = "abi_flags={} is_macos={} is_windows={}".format(abi_flags, is_macos, is_windows)
        content = _build_file(abi_flags, is_macos = is_macos, is_windows = is_windows)
        asserts.equals(env, 1 if defined else 0, content.count('defines = ["Py_GIL_DISABLED"],'), case)
        asserts.false(env, "defines = []" in content, case)

    return unittest.end(env)

python_headers_gil_disabled_test = unittest.make(_python_headers_gil_disabled_test_impl)

def repository_test_suite():
    unittest.suite(
        "repository_tests",
        feature_filegroups_exclude_pycache_test,
        freethreaded_stdlib_excludes_test,
        python_headers_gil_disabled_test,
    )
