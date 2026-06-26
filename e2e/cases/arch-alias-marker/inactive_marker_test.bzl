"""Analysis tests for inactive marker-only package and wheel aliases."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_python//python:defs.bzl", "PyInfo")

_CONFIG_SETTINGS = {
    "//command_line_option:platforms": str(Label("//cases/arch-alias-marker:inactive_linux_x86_64")),
    str(Label("@aspect_rules_py//uv/private/constraints/dep_group:dep_group")): "arch_alias_marker",
}

def _inactive_marker_package_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, PyInfo in target)
    if PyInfo in target:
        asserts.equals(env, [], target[PyInfo].transitive_sources.to_list())
    return analysistest.end(env)

inactive_marker_package_test = analysistest.make(
    _inactive_marker_package_test_impl,
    config_settings = _CONFIG_SETTINGS,
)

def _inactive_marker_wheel_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, [], target[DefaultInfo].files.to_list())
    return analysistest.end(env)

inactive_marker_wheel_test = analysistest.make(
    _inactive_marker_wheel_test_impl,
    config_settings = _CONFIG_SETTINGS,
)
