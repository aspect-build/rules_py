"""Tests for marker_simplify.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":marker_simplify.bzl", "simplify_extra_marker")

def _simplify_extra_marker_test_impl(ctx):
    env = unittest.begin(ctx)

    # Markers without `extra` pass through, re-rendered with normalized quoting.
    asserts.equals(env, "", simplify_extra_marker("", "build"))
    asserts.equals(env, "sys_platform == \"win32\"", simplify_extra_marker("sys_platform == 'win32'", "build"))

    # A matching extra collapses the marker to true ("").
    asserts.equals(env, "", simplify_extra_marker("extra == 'build'", "build"))

    # A non-matching extra collapses to false (None), dropping the edge.
    asserts.equals(env, None, simplify_extra_marker("extra == 'build'", "other"))

    # Mixed markers reduce to their platform residual, or vanish per the extra.
    asserts.equals(env, "sys_platform == \"win32\"", simplify_extra_marker("extra == 'build' and sys_platform == 'win32'", "build"))
    asserts.equals(env, None, simplify_extra_marker("extra == 'build' and sys_platform == 'win32'", "other"))
    asserts.equals(env, "", simplify_extra_marker("extra == 'build' or sys_platform == 'win32'", "build"))
    asserts.equals(env, "sys_platform == \"win32\"", simplify_extra_marker("extra == 'build' or sys_platform == 'win32'", "other"))

    return unittest.end(env)

simplify_extra_marker_test = unittest.make(
    _simplify_extra_marker_test_impl,
)

def marker_simplify_test_suite():
    unittest.suite(
        "marker_simplify_tests",
        simplify_extra_marker_test,
    )
