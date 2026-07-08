"""Tests for marker_simplify.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":marker_simplify.bzl", "is_extra_only_marker", "simplify_extra_marker", "simplify_markers_for_extras")

def _simplify_extra_marker_test_impl(ctx):
    env = unittest.begin(ctx)

    # Markers that don't reference `extra` pass through untouched.
    asserts.equals(env, "", simplify_extra_marker("", ["build"]))
    asserts.equals(env, "sys_platform == 'win32'", simplify_extra_marker("sys_platform == 'win32'", ["build"]))

    # Extra-only markers collapse to true ("") or false (None).
    asserts.equals(env, "", simplify_extra_marker("extra == 'build'", ["build"]))
    asserts.equals(env, "", simplify_extra_marker("extra == 'build'", ["other", "build"]))
    asserts.equals(env, "", simplify_extra_marker("extra != 'build'", ["other"]))
    asserts.equals(env, None, simplify_extra_marker("extra == 'build'", ["other"]))
    asserts.equals(env, None, simplify_extra_marker("extra == 'build'", []))

    # Mixed markers reduce to their platform residual. Residuals are re-rendered
    # by the evaluator with normalized (double) quoting.
    asserts.equals(env, "sys_platform == \"win32\"", simplify_extra_marker("extra == 'build' and sys_platform == 'win32'", ["build"]))
    asserts.equals(env, None, simplify_extra_marker("extra == 'build' and sys_platform == 'win32'", ["other"]))
    asserts.equals(env, "", simplify_extra_marker("extra == 'build' or sys_platform == 'win32'", ["build"]))
    asserts.equals(env, "sys_platform == \"win32\"", simplify_extra_marker("extra == 'build' or sys_platform == 'win32'", ["other"]))

    # Identical residuals from several active extras are deduplicated.
    asserts.equals(env, "sys_platform == \"win32\"", simplify_extra_marker("extra == 'build' or sys_platform == 'win32'", ["a", "b"]))

    # Distinct residuals are joined under `or`.
    asserts.equals(
        env,
        "((sys_platform == \"win32\")) or ((os_name == \"nt\"))",
        simplify_extra_marker("(extra == 'a' and sys_platform == 'win32') or (extra == 'b' and os_name == 'nt')", ["a", "b"]),
    )

    return unittest.end(env)

simplify_extra_marker_test = unittest.make(
    _simplify_extra_marker_test_impl,
)

def _simplify_markers_for_extras_test_impl(ctx):
    env = unittest.begin(ctx)

    # True markers collapse to the unconditional "" marker; untouched markers
    # keep their original spelling.
    asserts.equals(
        env,
        {"": 1, "sys_platform == 'win32'": 1},
        simplify_markers_for_extras({"extra == 'build'": 1, "sys_platform == 'win32'": 1}, ["build"]),
    )

    # False markers are dropped; all-false collections become empty.
    asserts.equals(
        env,
        {},
        simplify_markers_for_extras({"extra == 'build'": 1}, ["other"]),
    )

    return unittest.end(env)

simplify_markers_for_extras_test = unittest.make(
    _simplify_markers_for_extras_test_impl,
)

def _is_extra_only_marker_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.true(env, is_extra_only_marker("extra == 'build'"))
    asserts.true(env, is_extra_only_marker("'build' == extra"))
    asserts.true(env, is_extra_only_marker("extra != 'build'"))

    # uv conflict-routing markers, including conjunctions.
    asserts.true(env, is_extra_only_marker("extra == 'group-9-project-dev'"))
    asserts.true(env, is_extra_only_marker("extra == 'a' and extra != 'b'"))
    asserts.true(env, is_extra_only_marker("(extra == 'a') or (extra == 'b')"))

    asserts.false(env, is_extra_only_marker(""))
    asserts.false(env, is_extra_only_marker("sys_platform == 'win32'"))
    asserts.false(env, is_extra_only_marker("extra == 'build' and sys_platform == 'win32'"))

    # "extra" appearing only inside a string literal doesn't qualify.
    asserts.false(env, is_extra_only_marker("platform_machine == 'extra'"))

    return unittest.end(env)

is_extra_only_marker_test = unittest.make(
    _is_extra_only_marker_test_impl,
)

def marker_simplify_test_suite():
    unittest.suite(
        "marker_simplify_tests",
        simplify_extra_marker_test,
        simplify_markers_for_extras_test,
        is_extra_only_marker_test,
    )
