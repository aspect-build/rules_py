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

def repository_test_suite():
    unittest.suite(
        "repository_tests",
        feature_filegroups_exclude_pycache_test,
    )
