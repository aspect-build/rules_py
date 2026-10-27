"""Tests for repository.bzl BUILD generation."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//py/private/interpreter:exclude_feature.bzl", "INTERPRETER_FEATURES")
load("//py/private/interpreter:repository.bzl", "repository_testlib")

_PYCACHE_EXCLUDE = 'exclude = ["**/__pycache__/*.pyc*"]'

def _feature_filegroups_exclude_pycache_test_impl(ctx):
    env = unittest.begin(ctx)

    targets, excludes = repository_testlib.feature_filegroups("3", "13", False, False)

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
    asserts.equals(env, ("", []), repository_testlib.feature_filegroups("3", "13", True, False))

    return unittest.end(env)

feature_filegroups_exclude_pycache_test = unittest.make(_feature_filegroups_exclude_pycache_test_impl)

def _build_file(precompiled, is_windows = False):
    return repository_testlib.build_file_content(
        major = "3",
        minor = "14",
        micro = "0",
        python_bin = "python.exe" if is_windows else "bin/python3",
        is_macos = False,
        is_windows = is_windows,
        abi_flags = "",
        releaselevel = "final",
        serial = "0",
        precompiled = precompiled,
    )

_PRECOMPILED_PATTERNS = ["**/__pycache__/*.opt-*.pyc*", "**/test/**/__pycache__/**", "**/tests/**/__pycache__/**"]

def _precompiled_stdlib_keeps_bytecode_test_impl(ctx):
    env = unittest.begin(ctx)

    for is_windows, globs in [(False, 1 + len(INTERPRETER_FEATURES)), (True, 1)]:
        # With the precompile flag, the precompiled bytecode is kept, since it
        # is never rewritten. Python can still write optimized bytecode and the
        # test suites' bytecode, so those stay out of _core and every feature.
        # Without the flag, every glob leaves out all bytecode, as it does
        # when nothing was precompiled.
        content = _build_file(True, is_windows = is_windows)
        asserts.equals(env, globs, content.count(repr("@aspect_rules_py//uv/private/pyc:is_precompile")))
        asserts.equals(env, globs, content.count(repr("**/__pycache__/*.pyc*")))
        for pattern in _PRECOMPILED_PATTERNS:
            asserts.equals(env, globs, content.count(repr(pattern)), pattern)

        content = _build_file(False, is_windows = is_windows)
        asserts.false(env, "is_precompile" in content)
        asserts.equals(env, globs, content.count(repr("**/__pycache__/*.pyc*")))
        for pattern in _PRECOMPILED_PATTERNS:
            asserts.false(env, repr(pattern) in content, pattern)

    return unittest.end(env)

precompiled_stdlib_keeps_bytecode_test = unittest.make(_precompiled_stdlib_keeps_bytecode_test_impl)

def repository_test_suite():
    unittest.suite(
        "repository_tests",
        feature_filegroups_exclude_pycache_test,
        precompiled_stdlib_keeps_bytecode_test,
    )
