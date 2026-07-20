"""Analysis coverage for invalid multi-launcher image-layer configurations."""

load("@aspect_rules_py//py:defs.bzl", "py_binary", "py_image_layer", "py_layer_tier", "py_library")
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

def _configured_tree_or_file_impl(ctx):
    if ctx.attr.tree:
        out = ctx.actions.declare_directory("generated_tree")
        ctx.actions.run_shell(
            outputs = [out],
            command = "mkdir -p \"$1\" && echo tree > \"$1/support.py\"",
            arguments = [out.path],
        )
    else:
        out = ctx.actions.declare_file("generated_tree/support.py")
        ctx.actions.write(out, "file\n")
    return [DefaultInfo(files = depset([out]), runfiles = ctx.runfiles(files = [out]))]

_configured_tree_or_file = rule(
    implementation = _configured_tree_or_file_impl,
    attrs = {"tree": attr.bool()},
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
    native.genrule(
        name = "_generated_support",
        outs = ["generated_support.py"],
        cmd = select({
            ":_python_3_11": "echo 'VALUE = 11' > $@",
            "//conditions:default": "echo 'VALUE = 12' > $@",
        }),
    )
    py_library(
        name = "_generated_support_lib",
        srcs = [":_generated_support"],
        imports = ["."],
    )
    py_binary(
        name = "_configured_group_311",
        srcs = ["server.py"],
        python_version = "3.11",
        deps = [":_generated_support_lib"],
    )
    py_binary(
        name = "_configured_group_312",
        srcs = ["server.py"],
        python_version = "3.12",
        deps = [":_generated_support_lib"],
    )
    py_binary(
        name = "_configured_source_312",
        srcs = ["server.py"],
        data = [":_generated_support"],
        python_version = "3.12",
    )
    py_layer_tier(
        name = "_generated_support_tier",
        groups = {"//oci/py_image_layer:_generated_support_lib": "generated_support"},
    )

    py_image_layer(
        name = "_configured_group_collision_layers",
        binary = ":_configured_group_311",
        additional_binaries = [":_configured_group_312"],
        launcher_dir = "/app/bin",
        layer_tier = ":_generated_support_tier",
    )
    _expected_failure_test(
        name = "configured_group_collision_test",
        expected_error = "py_image_layer runfile collision at ./app.runfiles/_main/oci/py_image_layer/generated_support.py",
        target_under_test = ":_configured_group_collision_layers",
    )

    py_image_layer(
        name = "_configured_group_source_collision_layers",
        binary = ":_configured_group_311",
        additional_binaries = [":_configured_source_312"],
        launcher_dir = "/app/bin",
        layer_tier = ":_generated_support_tier",
    )
    _expected_failure_test(
        name = "configured_group_source_collision_test",
        expected_error = "py_image_layer runfile collision at ./app.runfiles/_main/oci/py_image_layer/generated_support.py",
        target_under_test = ":_configured_group_source_collision_layers",
    )

    # Manual action-failure fixture: the 3.11 tree expands in the grouped tar,
    # while the 3.12 file lands in the default tar. The global mtree validator
    # must reject their shared destination.
    _configured_tree_or_file(
        name = "_configured_tree_or_file",
        tree = select({
            ":_python_3_11": True,
            "//conditions:default": False,
        }),
    )
    py_library(
        name = "_configured_tree_lib",
        srcs = [":_configured_tree_or_file"],
        imports = ["."],
    )
    py_binary(
        name = "_configured_tree_311",
        srcs = ["server.py"],
        python_version = "3.11",
        deps = [":_configured_tree_lib"],
    )
    py_binary(
        name = "_configured_file_312",
        srcs = [
            "server.py",
            ":_configured_tree_or_file",
        ],
        main = "server.py",
        python_version = "3.12",
    )
    py_layer_tier(
        name = "_configured_tree_tier",
        groups = {"//oci/py_image_layer:_configured_tree_lib": "generated_tree"},
    )
    py_image_layer(
        name = "_expanded_tree_collision_layers",
        binary = ":_configured_tree_311",
        additional_binaries = [":_configured_file_312"],
        launcher_dir = "/app/bin",
        layer_tier = ":_configured_tree_tier",
    )

    # Manual action-failure fixture for a rule-level group built in the image
    # configuration colliding with a transitioned binary source file.
    py_image_layer(
        name = "_rule_group_collision_layers",
        binary = ":_configured_group_311",
        groups = {":_generated_support": "generated_support"},
    )

    py_binary(
        name = "_same_group_source_bin",
        srcs = ["server.py"],
        data = [":_generated_support"],
    )
    py_image_layer(
        name = "_same_rule_group_source_layers",
        binary = ":_same_group_source_bin",
        groups = {":_generated_support": "generated_support"},
    )

    # Manual action-failure fixture for unversioned wheel script/data paths
    # shared by separately configured whl_install trees.
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
        binary = ":_wheel_scripts_311",
        additional_binaries = [":_wheel_scripts_312"],
        launcher_dir = "/app/bin",
        layer_tier = ":_wheel_scripts_tier",
    )
