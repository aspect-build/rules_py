"""Analysis coverage for invalid multi-launcher image-layer configurations."""

load("@aspect_rules_py//py:defs.bzl", "py_binary", "py_image_layer", "py_layer_tier", "py_library")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _expected_failure_impl(ctx):
    env = analysistest.begin(ctx)
    for expected_error in ctx.attr.expected_errors:
        asserts.expect_failure(env, expected_error)
    return analysistest.end(env)

_expected_failure_test = analysistest.make(
    _expected_failure_impl,
    attrs = {"expected_errors": attr.string_list(mandatory = True)},
    expect_failure = True,
)

def _source_tree_impl(ctx):
    out = ctx.actions.declare_directory("piecewise_tree")
    ctx.actions.run_shell(
        outputs = [out],
        command = "mkdir -p \"$1/nested\" && echo tree > \"$1/nested/support.py\"",
        arguments = [out.path],
    )
    return [DefaultInfo(files = depset([out]), runfiles = ctx.runfiles(files = [out]))]

_source_tree = rule(implementation = _source_tree_impl)

def _regular_path_impl(ctx):
    out = ctx.actions.declare_file("regular_collision" if ctx.attr.ancestor else "regular_collision/child.py")
    ctx.actions.write(out, "regular\n")
    return [DefaultInfo(files = depset([out]), runfiles = ctx.runfiles(files = [out]))]

_regular_path = rule(
    implementation = _regular_path_impl,
    attrs = {"ancestor": attr.bool()},
)

def image_layer_analysis_test_suite():
    py_image_layer(
        name = "_missing_launcher_dir_layers",
        binaries = [":my_app_bin", ":my_app_worker_bin"],
    )
    _expected_failure_test(
        name = "missing_launcher_dir_test",
        expected_errors = ["py_image_layer with multiple binaries requires launcher_dir"],
        target_under_test = ":_missing_launcher_dir_layers",
    )

    py_image_layer(
        name = "_relative_launcher_dir_layers",
        binaries = [":my_app_bin", ":my_app_worker_bin"],
        launcher_dir = "app/bin",
    )
    _expected_failure_test(
        name = "relative_launcher_dir_test",
        expected_errors = ["py_image_layer.launcher_dir must be an absolute image path"],
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
        expected_errors = ["duplicate py_image_layer launcher basename: my_app_bin"],
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
    _expected_failure_test(
        name = "configured_wheel_collision_test",
        expected_errors = [
            "py_image_layer runfile collision at",
            "actual_install.install:",
        ],
        target_under_test = ":_configured_wheel_collision_layers",
    )

    _source_tree(name = "_piecewise_tree")
    py_binary(
        name = "_piecewise_tree_bin",
        srcs = ["server.py"],
        data = [":_piecewise_tree"],
    )
    py_layer_tier(
        name = "_piecewise_tree_tier",
        strip_prefix = "oci/py_image_layer/piecewise_tree/nested",
    )
    py_image_layer(
        name = "_piecewise_tree_layers",
        binaries = [":_piecewise_tree_bin", ":my_app_bin"],
        launcher_dir = "/app/bin",
        layer_tier = ":_piecewise_tree_tier",
    )
    _expected_failure_test(
        name = "piecewise_tree_test",
        expected_errors = ["py_image_layer cannot map TreeArtifact across strip_prefix"],
        target_under_test = ":_piecewise_tree_layers",
    )

    py_image_layer(
        name = "_interpreter_group_collision_layers",
        binary = ":my_app_bin",
        groups = {":worker_support": "interpreter"},
        layer_tier = ":my_app_launchers_tier",
    )
    _expected_failure_test(
        name = "interpreter_group_collision_test",
        expected_errors = ["Group \"interpreter\" is declared in both py_image_layer.groups and the active py_layer_tier"],
        target_under_test = ":_interpreter_group_collision_layers",
    )

    _regular_path(
        name = "_regular_path",
        ancestor = select({
            ":_python_3_11": True,
            "//conditions:default": False,
        }),
    )
    py_library(
        name = "_regular_path_lib",
        srcs = [":_regular_path"],
        imports = ["."],
    )
    py_binary(
        name = "_regular_path_311",
        srcs = ["server.py"],
        python_version = "3.11",
        deps = [":_regular_path_lib"],
    )
    py_binary(
        name = "_regular_path_312",
        srcs = ["server.py"],
        python_version = "3.12",
        deps = [":_regular_path_lib"],
    )
    py_image_layer(
        name = "_regular_path_collision_layers",
        binaries = [":_regular_path_311", ":_regular_path_312"],
        launcher_dir = "/app/bin",
    )
    _expected_failure_test(
        name = "regular_path_collision_test",
        expected_errors = [
            "py_image_layer runfile collision at",
            "regular_collision/child.py",
        ],
        target_under_test = ":_regular_path_collision_layers",
    )
