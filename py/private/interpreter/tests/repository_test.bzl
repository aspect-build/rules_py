"""Tests for repository.bzl BUILD generation."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//py/private/interpreter:exclude_feature.bzl", "INTERPRETER_FEATURES")
load("//py/private/interpreter:repository.bzl", "repository_testlib")

_PYCACHE_EXCLUDE = 'exclude = ["**/__pycache__/*.pyc*"]'

def _feature_filegroups_exclude_pycache_test_impl(ctx):
    env = unittest.begin(ctx)

    targets, excludes = repository_testlib.feature_filegroups("3", "13", False)

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
    asserts.equals(env, ("", []), repository_testlib.feature_filegroups("3", "13", True))

    return unittest.end(env)

feature_filegroups_exclude_pycache_test = unittest.make(_feature_filegroups_exclude_pycache_test_impl)

def _python_headers_defines(is_macos, is_windows, abi_flags):
    content = repository_testlib.build_file_content(
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
    headers = content[content.index('    name = "python_headers",'):]
    headers = headers[:headers.index("\n)\n")]
    return [line.strip() for line in headers.splitlines() if line.strip().startswith("defines = ")]

def _python_headers_gil_disabled_test_impl(ctx):
    env = unittest.begin(ctx)

    # Windows has one pyconfig.h for both builds, so only the free-threaded
    # Windows headers define Py_GIL_DISABLED themselves.
    asserts.equals(env, ['defines = ["Py_GIL_DISABLED"],'], _python_headers_defines(False, True, "t"))
    asserts.equals(env, ['defines = ["Py_GIL_DISABLED"],'], _python_headers_defines(False, True, "td"))
    asserts.equals(env, ["defines = [],"], _python_headers_defines(False, True, ""))

    # The free-threaded pyconfig.h defines it on Linux and macOS.
    asserts.equals(env, ["defines = [],"], _python_headers_defines(False, False, "t"))
    asserts.equals(env, ["defines = [],"], _python_headers_defines(True, False, "t"))

    return unittest.end(env)

python_headers_gil_disabled_test = unittest.make(_python_headers_gil_disabled_test_impl)

def repository_test_suite():
    unittest.suite(
        "repository_tests",
        feature_filegroups_exclude_pycache_test,
        python_headers_gil_disabled_test,
    )
