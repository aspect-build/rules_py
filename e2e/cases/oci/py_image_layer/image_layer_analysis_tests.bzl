"""Analysis and validation fixtures for multi-launcher image layers."""

load("@aspect_rules_py//py:defs.bzl", "py_binary", "py_image_layer", "py_layer_tier")
load("@bazel_features//:features.bzl", "bazel_features")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_PY_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"

def _expected_failure_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_error)
    return analysistest.end(env)

_expected_failure_test = analysistest.make(
    _expected_failure_impl,
    attrs = {"expected_error": attr.string(mandatory = True)},
    expect_failure = True,
)

def _target_file_symlink_impl(ctx):
    output = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = output, target_file = ctx.file.target)
    return [DefaultInfo(files = depset([output]))]

_target_file_symlink = rule(
    implementation = _target_file_symlink_impl,
    attrs = {"target": attr.label(allow_single_file = True, mandatory = True)},
)

def _interpreter_symlink_impl(ctx):
    output = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(
        output = output,
        target_file = ctx.toolchains[_PY_TOOLCHAIN].py3_runtime.interpreter,
    )
    return [DefaultInfo(files = depset([output]))]

_interpreter_symlink = rule(
    implementation = _interpreter_symlink_impl,
    toolchains = [_PY_TOOLCHAIN],
)

def _relative_symlink_impl(ctx):
    output = ctx.actions.declare_symlink(ctx.label.name)
    ctx.actions.symlink(output = output, target_path = ctx.attr.target_path)
    return [DefaultInfo(files = depset([output]))]

_relative_symlink = rule(
    implementation = _relative_symlink_impl,
    attrs = {"target_path": attr.string(mandatory = True)},
)

def _image_layer_failure(name, expected_error, **kwargs):
    target = "_{}_layers".format(name)
    py_image_layer(name = target, **kwargs)
    _expected_failure_test(
        name = name + "_test",
        expected_error = expected_error,
        target_under_test = ":" + target,
    )

def image_layer_analysis_test_suite():
    _image_layer_failure(
        name = "relative_launcher_dir",
        expected_error = "py_image_layer.launcher_dir must be an absolute image path",
        binaries = [":my_app_bin", ":my_app_worker_bin"],
        launcher_dir = "app/bin",
    )

    native.alias(
        name = "_my_app_bin_alias",
        actual = ":my_app_bin",
    )
    _image_layer_failure(
        name = "duplicate_launcher_basename",
        expected_error = "duplicate py_image_layer launcher basename: my_app_bin",
        binaries = [":my_app_bin", ":_my_app_bin_alias"],
        launcher_dir = "////",
    )

    native.config_setting(
        name = "_python_3_11",
        flag_values = {"@aspect_rules_py//py/private/interpreter:python_version": "3.11"},
    )

    for prefix, package in [("wheel_scripts", "build"), ("pure_wheel", "colorama")]:
        for version in ["3.11", "3.12"]:
            py_binary(
                name = "_{}_{}".format(prefix, version.replace(".", "")),
                srcs = ["server.py"],
                dep_group = "images",
                python_version = version,
                deps = ["@pypi_oci_py_image_layer//" + package],
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

    py_image_layer(
        name = "_configured_pure_wheel_layers",
        binaries = [":_pure_wheel_311", ":_pure_wheel_312"],
        launcher_dir = "/app/bin",
    )

    native.genrule(
        name = "_repo_mapping_shared_target",
        outs = ["repo_mapping/shared.txt"],
        cmd = "printf shared-link-ok > $@",
    )
    _relative_symlink(
        name = "_repo_mapping_link=shared",
        target_path = "repo_mapping/shared.txt",
    )
    py_binary(
        name = "_repo_mapping_images_bin",
        srcs = ["server.py"],
        data = [
            ":_repo_mapping_link=shared",
            ":_repo_mapping_shared_target",
        ],
        dep_group = "images",
        python_version = "3.11",
        deps = ["@pypi_oci_py_image_layer//colorama"],
    )
    py_binary(
        name = "_repo_mapping_venv_bin",
        srcs = ["server.py"],
        data = [
            ":_repo_mapping_link=shared",
            ":_repo_mapping_shared_target",
        ],
        dep_group = "venv_images",
        python_version = "3.12",
        deps = ["@pypi_oci_py_venv_image_layer//colorama"],
    )
    py_layer_tier(
        name = "_repo_mapping_tier",
        root = "/srv",
        strip_prefix = "oci/py_image_layer",
    )
    external_launcher = Label("@aspect_rules_py//py/tests/internal-deps/adder:external_launcher")
    py_layer_tier(
        name = "_external_scalar_tier",
        strip_prefix = "../{}/{}".format(external_launcher.workspace_name, external_launcher.package),
    )
    py_image_layer(
        name = "_external_scalar_layers",
        binary = external_launcher,
    )
    py_image_layer(
        name = "_external_scalar_stripped_layers",
        binary = external_launcher,
        layer_tier = ":_external_scalar_tier",
    )
    native.genrule(
        name = "_external_scalar_runtime_test",
        srcs = [
            ":_external_scalar_layers",
            ":_external_scalar_stripped_layers",
        ],
        outs = ["_external_scalar_runtime_test.ok"],
        cmd = """
set -eu
default_root="$(@D)/_external_scalar_runtime_test.default"
stripped_root="$(@D)/_external_scalar_runtime_test.stripped"
mkdir -p "$$default_root" "$$stripped_root"
for archive in $(locations :_external_scalar_layers); do
  $(BSDTAR_BIN) -xf "$$archive" -C "$$default_root"
done
for archive in $(locations :_external_scalar_stripped_layers); do
  $(BSDTAR_BIN) -xf "$$archive" -C "$$stripped_root"
done
RUNFILES_DIR="$$default_root/app.runfiles" "$$default_root/app" > "$$default_root/external.out"
RUNFILES_DIR="$$stripped_root/app.runfiles" "$$stripped_root/app/external_launcher" > "$$stripped_root/external.out"
test "$$(cat "$$default_root/external.out")" = "external 5"
test "$$(cat "$$stripped_root/external.out")" = "external 5"
touch $@
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )
    py_image_layer(
        name = "_repo_mapping_layers",
        binaries = [
            ":_repo_mapping_images_bin",
            ":_repo_mapping_venv_bin",
            "@aspect_rules_py//py/tests/internal-deps/adder:external_launcher",
        ],
        launcher_dir = "/app/bin",
        layer_tier = ":_repo_mapping_tier",
    )
    native.genrule(
        name = "_repo_mapping_runtime_test",
        srcs = [":_repo_mapping_layers"],
        outs = ["_repo_mapping_runtime_test.ok"],
        cmd = """
set -eu
root="$(@D)/_repo_mapping_runtime_test.root"
mkdir -p "$$root"
for archive in $(SRCS); do
  $(BSDTAR_BIN) -xf "$$archive" -C "$$root"
done
mapping="$$root/app.runfiles/_repo_mapping"
count="$$(for archive in $(SRCS); do $(BSDTAR_BIN) -tf "$$archive"; done | awk '/\\/app.runfiles\\/_repo_mapping$$/ { n++ } END { print n + 0 }')"
test "$$count" -eq 1
grep -Fq ',whl_install__images__colorama__0_4_6,' "$$mapping"
grep -Fq ',whl_install__venv_images__colorama__0_4_6,' "$$mapping"
RUNFILES_DIR="$$root/app.runfiles" "$$root/app/bin/_repo_mapping_images_bin" > "$$root/images.out"
RUNFILES_DIR="$$root/app.runfiles" "$$root/app/bin/_repo_mapping_venv_bin" > "$$root/venv.out"
RUNFILES_DIR="$$root/app.runfiles" "$$root/app/bin/external_launcher" > "$$root/external.out"
test "$$(cat "$$root/images.out")" = "server ok"
test "$$(cat "$$root/venv.out")" = "server ok"
test "$$(cat "$$root/external.out")" = "external 5"
test -L "$$root/app.runfiles/_main/oci/py_image_layer/_repo_mapping_link=shared"
test "$$(cat "$$root/app.runfiles/_main/oci/py_image_layer/_repo_mapping_link=shared")" = "shared-link-ok"
touch $@
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    native.genrule(
        name = "_grouped_tool",
        outs = ["grouped/tool.sh"],
        cmd = "printf '#!/bin/sh\\nprintf grouped-ok\\n' > $@",
        executable = True,
    )
    native.genrule(
        name = "_grouped_payload",
        outs = ["grouped/content=payload.txt"],
        cmd = "printf grouped-payload > $@",
    )
    native.genrule(
        name = "_group_only_file",
        outs = ["grouped/ordinary.txt"],
        cmd = "printf ordinary > $@",
    )
    _target_file_symlink(
        name = "_grouped_content=payload_link",
        target = ":_grouped_payload",
    )
    _target_file_symlink(
        name = "_grouped_content=asset_link",
        target = ":_group_only_file",
    )
    native.filegroup(
        name = "_grouped_assets",
        srcs = [
            ":_group_only_file",
            ":_grouped_content=payload_link",
            ":_grouped_tool",
        ],
    )
    py_binary(
        name = "_grouped_source_bin",
        srcs = ["server.py"],
        data = [
            ":_grouped_content=asset_link",
            ":_grouped_payload",
            ":_grouped_tool",
        ],
    )
    py_image_layer(
        name = "_grouped_source_layers",
        binaries = [
            ":_grouped_source_bin",
            ":my_app_bin",
        ],
        groups = {
            ":_grouped_assets": "assets",
            ":_grouped_source_bin": "launcher",
        },
        launcher_dir = "/app/bin",
    )
    _interpreter_symlink(
        name = "_grouped_interpreter_link",
    )
    py_binary(
        name = "_grouped_interpreter_bin",
        srcs = ["server.py"],
        data = [":_grouped_interpreter_link"],
    )
    py_layer_tier(
        name = "_grouped_interpreter_tier",
        interpreter_group = "interpreter",
    )
    py_image_layer(
        name = "_grouped_interpreter_layers",
        binary = ":_grouped_interpreter_bin",
        groups = {":_grouped_interpreter_link": "interpreter_alias"},
        layer_tier = ":_grouped_interpreter_tier",
    )
    native.genrule(
        name = "_grouped_source_runtime_test",
        srcs = [
            ":_grouped_source_layers_no_src",
            ":_grouped_source_layers_only_src",
            ":_grouped_interpreter_layers",
            ":_scalar_launcher_collision_layers",
        ],
        outs = ["_grouped_source_runtime_test.ok"],
        cmd = """
set -eu
root="$(@D)/_grouped_source_runtime_test.root"
interpreter_root="$(@D)/_grouped_source_runtime_test.interpreter"
scalar_root="$(@D)/_grouped_source_runtime_test.scalar"
mkdir -p "$$root" "$$interpreter_root" "$$scalar_root"
for archive in $(locations :_grouped_source_layers_no_src) $(locations :_grouped_source_layers_only_src); do
  $(BSDTAR_BIN) -xf "$$archive" -C "$$root"
done
for archive in $(locations :_grouped_interpreter_layers); do
  $(BSDTAR_BIN) -xf "$$archive" -C "$$interpreter_root"
done
for archive in $(locations :_scalar_launcher_collision_layers); do
  $(BSDTAR_BIN) -xf "$$archive" -C "$$scalar_root"
done
prefix="$$root/app.runfiles/_main/oci/py_image_layer"
test "$$("$$prefix/grouped/tool.sh")" = grouped-ok
test ! -x "$$prefix/grouped/ordinary.txt"
test -L "$$prefix/_grouped_content=payload_link"
test "$$(cat "$$prefix/_grouped_content=payload_link")" = grouped-payload
test -L "$$prefix/_grouped_content=asset_link"
test "$$(cat "$$prefix/_grouped_content=asset_link")" = ordinary
interpreter_link="$$interpreter_root/app.runfiles/_main/oci/py_image_layer/_grouped_interpreter_link"
test -L "$$interpreter_link"
test -s "$$interpreter_link"
test "$$("$$interpreter_link" -c 'print("interpreter-link-ok")')" = interpreter-link-ok
RUNFILES_DIR="$$root/app.runfiles" "$$root/app/bin/_grouped_source_bin" > "$$root/launcher.out"
test "$$(cat "$$root/launcher.out")" = "server ok"
RUNFILES_DIR="$$scalar_root/app.runfiles" "$$scalar_root/app/bin/_scalar_launcher_collision" > "$$scalar_root/launcher.out"
test "$$(cat "$$scalar_root/launcher.out")" = "server ok"
test "$$(cat "$$scalar_root/app.runfiles/_main/oci/py_image_layer/bin/_scalar_launcher_collision")" = data
count="$$(for archive in $(locations :_grouped_source_layers_no_src) $(locations :_grouped_source_layers_only_src); do $(BSDTAR_BIN) -tf "$$archive"; done | awk '/\\/grouped\\/content=payload.txt$$/ { n++ } END { print n + 0 }')"
test "$$count" -eq 1
count="$$(for archive in $(locations :_grouped_source_layers_no_src) $(locations :_grouped_source_layers_only_src); do $(BSDTAR_BIN) -tf "$$archive"; done | awk '/\\/grouped\\/ordinary.txt$$/ { n++ } END { print n + 0 }')"
test "$$count" -eq 1
count="$$(for archive in $(locations :_grouped_interpreter_layers); do $(BSDTAR_BIN) -tvf "$$archive"; done | awk '$$1 ~ /^-/ && $$NF ~ /\\/bin\\/python3\\.[0-9]+$$/ { n++ } END { print n + 0 }')"
test "$$count" -eq 1
count="$$(for archive in $(locations :_grouped_interpreter_layers); do $(BSDTAR_BIN) -tf "$$archive"; done | awk '/\\/_grouped_interpreter_link$$/ { n++ } END { print n + 0 }')"
test "$$count" -eq 1
count="$$(for archive in $(locations :_grouped_source_layers_no_src); do $(BSDTAR_BIN) -tf "$$archive"; done | awk '/\\/app\\/bin\\/_grouped_source_bin$$/ { n++ } END { print n + 0 }')"
test "$$count" -eq 1
if for archive in $(locations :_grouped_source_layers_only_src); do $(BSDTAR_BIN) -tf "$$archive"; done | grep -q '/app/bin/_grouped_source_bin$$'; then
  exit 1
fi
touch $@
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
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

    py_layer_tier(
        name = "_scalar_default_tier",
        interpreter_group = "interpreter",
    )
    py_image_layer(
        name = "_scalar_default_layers",
        binary = ":my_app_peer_bin",
        layer_tier = ":_scalar_default_tier",
    )
    py_image_layer(
        name = "_scalar_default_binaries_layers",
        binaries = [":my_app_peer_bin"],
        layer_tier = ":_scalar_default_tier",
    )
    native.genrule(
        name = "_scalar_default_sources_listing",
        srcs = [
            ":_scalar_default_binaries_layers_only_src",
            ":_scalar_default_layers_only_src",
        ],
        outs = ["_scalar_default_sources.listing"],
        cmd = "for f in $(SRCS); do $(BSDTAR_BIN) -tf $$f; done > $@",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    py_binary(
        name = "_scalar_root_collision",
        srcs = ["server.py"],
    )
    py_layer_tier(
        name = "_scalar_root_collision_tier",
        root = "/app.runfiles/_main/oci/py_image_layer/server.py",
    )
    py_image_layer(
        name = "_scalar_root_collision_layers",
        binary = ":_scalar_root_collision",
        layer_tier = ":_scalar_root_collision_tier",
    )

    # Bazel 8 permits nested runfiles outputs. Bazel 9 rejects this topology
    # before analysis, so keep the real longest-prefix regression Bazel-8-only.
    if not bazel_features.rules.merkle_cache_v2:
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
            strip_prefix = "oci/py_image_layer/_nested_prefix",
        )
        py_layer_tier(
            name = "_nested_prefix_nonmatching_tier",
            interpreter_group = "interpreter",
            strip_prefix = "does/not/match",
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
        py_image_layer(
            name = "_nested_prefix_scalar_layers",
            binary = ":_nested_prefix/foo.runfiles/worker",
            layer_tier = ":_nested_prefix_tier",
        )
        py_image_layer(
            name = "_nested_prefix_nonmatching_scalar_layers",
            binary = ":_nested_prefix/foo.runfiles/worker",
            layer_tier = ":_nested_prefix_nonmatching_tier",
        )
        native.genrule(
            name = "_nested_prefix_sources_listing",
            srcs = [
                ":_nested_prefix_layers_only_src",
                ":_nested_prefix_nonmatching_scalar_layers_only_src",
                ":_nested_prefix_reversed_layers_only_src",
                ":_nested_prefix_scalar_layers_only_src",
            ],
            outs = ["_nested_prefix_sources.listing"],
            cmd = "for f in $(SRCS); do $(BSDTAR_BIN) -tf $$f; done > $@",
            toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
        )

    _image_layer_failure(
        name = "interpreter_group_collision",
        expected_error = "Group \"interpreter\" is declared in both py_image_layer.groups and the active py_layer_tier",
        binary = ":my_app_bin",
        groups = {":worker_support": "interpreter"},
        layer_tier = ":my_app_launchers_tier",
    )
