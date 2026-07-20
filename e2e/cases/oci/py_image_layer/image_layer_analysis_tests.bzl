"""Analysis coverage for invalid multi-launcher image-layer configurations."""

load("@aspect_rules_py//py:defs.bzl", "py_image_layer")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _expected_failure_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_error)
    return analysistest.end(env)

_expected_failure_test = analysistest.make(
    _expected_failure_impl,
    attrs = {"expected_error": attr.string(mandatory = True)},
    expect_failure = True,
)

def image_layer_analysis_test_suite():
    py_image_layer(
        name = "_missing_launcher_dir_layers",
        binary = ":my_app_bin",
        additional_binaries = [":my_app_worker_bin"],
    )
    _expected_failure_test(
        name = "missing_launcher_dir_test",
        expected_error = "py_image_layer with multiple binaries requires launcher_dir",
        target_under_test = ":_missing_launcher_dir_layers",
    )

    py_image_layer(
        name = "_relative_launcher_dir_layers",
        binary = ":my_app_bin",
        additional_binaries = [":my_app_worker_bin"],
        launcher_dir = "app/bin",
    )
    _expected_failure_test(
        name = "relative_launcher_dir_test",
        expected_error = "py_image_layer.launcher_dir must be an absolute image path",
        target_under_test = ":_relative_launcher_dir_layers",
    )

    native.alias(
        name = "_my_app_bin_alias",
        actual = ":my_app_bin",
    )
    py_image_layer(
        name = "_duplicate_launcher_layers",
        binary = ":my_app_bin",
        additional_binaries = [":_my_app_bin_alias"],
        launcher_dir = "/app/bin",
    )
    _expected_failure_test(
        name = "duplicate_launcher_basename_test",
        expected_error = "duplicate py_image_layer launcher basename: my_app_bin",
        target_under_test = ":_duplicate_launcher_layers",
    )
