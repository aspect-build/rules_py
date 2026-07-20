"""Analysis and validation fixtures for multi-launcher image layers."""

load("@aspect_rules_py//py:defs.bzl", "py_binary", "py_image_layer", "py_layer_tier")
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
        binaries = [":my_app_bin", ":my_app_worker_bin"],
    )
    _expected_failure_test(
        name = "missing_launcher_dir_test",
        expected_error = "py_image_layer with multiple binaries requires launcher_dir",
        target_under_test = ":_missing_launcher_dir_layers",
    )

    py_image_layer(
        name = "_relative_launcher_dir_layers",
        binaries = [":my_app_bin", ":my_app_worker_bin"],
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
        binaries = [":my_app_bin", ":_my_app_bin_alias"],
        launcher_dir = "////",
    )
    _expected_failure_test(
        name = "duplicate_launcher_basename_test",
        expected_error = "duplicate py_image_layer launcher basename: my_app_bin",
        target_under_test = ":_duplicate_launcher_layers",
    )

    native.config_setting(
        name = "_python_3_11",
        flag_values = {"@aspect_rules_py//py/private/interpreter:python_version": "3.11"},
    )

    py_binary(
        name = "_wheel_scripts_311",
        srcs = ["server.py"],
        dep_group = "images",
        python_version = "3.11",
        deps = ["@pypi_oci_py_image_layer//build"],
    )
    py_binary(
        name = "_wheel_scripts_312",
        srcs = ["server.py"],
        dep_group = "images",
        python_version = "3.12",
        deps = ["@pypi_oci_py_image_layer//build"],
    )
    py_layer_tier(
        name = "_wheel_scripts_tier",
        groups = {"@pip//build": "wheel_scripts"},
    )
    py_image_layer(
        name = "_configured_wheel_collision_layers",
        binaries = [":_wheel_scripts_311", ":_wheel_scripts_312"],
        launcher_dir = "/app/bin",
        layer_tier = ":_wheel_scripts_tier",
    )

    py_binary(
        name = "_pure_wheel_311",
        srcs = ["server.py"],
        dep_group = "images",
        python_version = "3.11",
        deps = ["@pypi_oci_py_image_layer//colorama"],
    )
    py_binary(
        name = "_pure_wheel_312",
        srcs = ["server.py"],
        dep_group = "images",
        python_version = "3.12",
        deps = ["@pypi_oci_py_image_layer//colorama"],
    )
    py_image_layer(
        name = "_configured_pure_wheel_layers",
        binaries = [":_pure_wheel_311", ":_pure_wheel_312"],
        launcher_dir = "/app/bin",
    )

    native.genrule(
        name = "_scalar_launcher_collision_data",
        outs = ["bin/_scalar_launcher_collision"],
        cmd = "echo data > $@",
    )
    py_binary(
        name = "_scalar_launcher_collision",
        srcs = ["server.py"],
        data = ["bin/_scalar_launcher_collision"],
    )
    py_layer_tier(
        name = "_scalar_launcher_collision_tier",
        strip_prefix = "oci/py_image_layer",
    )
    py_image_layer(
        name = "_scalar_launcher_collision_layers",
        binary = ":_scalar_launcher_collision",
        launcher_dir = "/app/bin",
        layer_tier = ":_scalar_launcher_collision_tier",
    )

    py_binary(
        name = "_scalar_strip_collision",
        srcs = ["server.py"],
        data = ["_scalar_strip_collision/data.txt"],
    )
    py_layer_tier(
        name = "_scalar_strip_collision_tier",
        root = "/app.runfiles/_main/oci/py_image_layer",
        strip_prefix = "oci/py_image_layer",
    )
    py_image_layer(
        name = "_scalar_strip_collision_layers",
        binary = ":_scalar_strip_collision",
        layer_tier = ":_scalar_strip_collision_tier",
    )

    py_binary(
        name = "_nested_prefix/foo",
        srcs = ["server.py"],
        python_version = "3.11",
    )
    native.genrule(
        name = "_nested_prefix_runfile",
        outs = ["_nested_prefix/foo.runfiles/worker.runfiles/_main/nested/data.txt"],
        cmd = "echo data > $@",
    )
    py_binary(
        name = "_nested_prefix/foo.runfiles/worker",
        srcs = ["server.py"],
        data = ["_nested_prefix/foo.runfiles/worker.runfiles/_main/nested/data.txt"],
        python_version = "3.12",
    )
    py_layer_tier(
        name = "_nested_prefix_tier",
        interpreter_group = "interpreter",
    )
    py_image_layer(
        name = "_nested_prefix_layers",
        binaries = [
            ":_nested_prefix/foo",
            ":_nested_prefix/foo.runfiles/worker",
        ],
        launcher_dir = "/app/bin",
        layer_tier = ":_nested_prefix_tier",
    )
    py_image_layer(
        name = "_nested_prefix_reversed_layers",
        binaries = [
            ":_nested_prefix/foo.runfiles/worker",
            ":_nested_prefix/foo",
        ],
        launcher_dir = "/app/bin",
        layer_tier = ":_nested_prefix_tier",
    )
    native.genrule(
        name = "_nested_prefix_sources_listing",
        srcs = [
            ":_nested_prefix_layers_only_src",
            ":_nested_prefix_reversed_layers_only_src",
        ],
        outs = ["_nested_prefix_sources.listing"],
        cmd = "for f in $(SRCS); do $(BSDTAR_BIN) -tf $$f; done > $@",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    py_image_layer(
        name = "_interpreter_group_collision_layers",
        binary = ":my_app_bin",
        groups = {":worker_support": "interpreter"},
        layer_tier = ":my_app_launchers_tier",
    )
    _expected_failure_test(
        name = "interpreter_group_collision_test",
        expected_error = "Group \"interpreter\" is declared in both py_image_layer.groups and the active py_layer_tier",
        target_under_test = ":_interpreter_group_collision_layers",
    )
