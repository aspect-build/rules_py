"""Fixtures for running Python tests under indexed imports."""

load("//py/private:providers.bzl", "PyWheelsInfo", "make_wheel_record")
load("//py/private:py_info.bzl", "PyInfo")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")
load("//uv/private/whl_install:metadata.bzl", "derive_layout")

_INDEXED_IMPORTS_FLAG = "//py:experimental_indexed_imports"

def _indexed_imports_impl(_settings, _attr):
    return {_INDEXED_IMPORTS_FLAG: True}

_indexed_imports_transition = transition(
    implementation = _indexed_imports_impl,
    inputs = [],
    outputs = [_INDEXED_IMPORTS_FLAG],
)

def _indexed_imports_test_impl(ctx):
    binary = ctx.attr.binary[0]
    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(
        output = executable,
        target_file = binary[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )
    providers = [DefaultInfo(
        executable = executable,
        runfiles = binary[DefaultInfo].default_runfiles,
    )]
    if RunEnvironmentInfo in binary:
        providers.append(binary[RunEnvironmentInfo])
    return providers

indexed_imports_test = rule(
    implementation = _indexed_imports_test_impl,
    doc = "Runs `binary` with `--//py:experimental_indexed_imports=true`.",
    test = True,
    attrs = {
        "binary": attr.label(
            cfg = _indexed_imports_transition,
            executable = True,
            mandatory = True,
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)

def _fixture_wheel_impl(ctx):
    py_runtime = ctx.toolchains[PY_TOOLCHAIN].py3_runtime
    major = py_runtime.interpreter_version_info.major
    minor = py_runtime.interpreter_version_info.minor
    install_tree = ctx.actions.declare_directory(ctx.label.name + ".install")
    site_rel = "lib/python{}.{}/site-packages".format(major, minor)
    metadata = "{}-1.0.dist-info".format(ctx.attr.distribution)
    files = dict(ctx.attr.files)
    files[metadata + "/METADATA"] = "Metadata-Version: 2.1\nName: {}\nVersion: 1.0\n".format(
        ctx.attr.distribution,
    )

    arguments = ctx.actions.args()
    arguments.add(install_tree.path + "/" + site_rel)
    for path, content in files.items():
        arguments.add_all([path, content])
    ctx.actions.run_shell(
        outputs = [install_tree],
        command = """
set -eu
site="$1"; shift
while [ "$#" -gt 0 ]; do
  mkdir -p "$(dirname "$site/$1")"
  printf '%s' "$2" > "$site/$1"
  shift 2
done
""",
        arguments = [arguments],
    )

    # Same layout derivation a uv-installed wheel gets from its RECORD.
    layout = derive_layout([path.split("/") for path in files])
    site_packages = "/".join([
        segment
        for segment in [ctx.label.repo_name or ctx.workspace_name, ctx.label.package, install_tree.basename]
        if segment
    ] + [site_rel])
    wheel = make_wheel_record(
        top_levels = layout.top_levels,
        top_level_dirs = layout.top_level_dirs,
        namespace_top_levels = layout.namespace_top_levels,
        namespace_entries = layout.namespace_entries,
        namespace_dirs = layout.namespace_dirs,
        regular_roots = layout.regular_roots,
        native_roots = layout.native_roots,
        site_packages_rfpath = site_packages,
        install_tree = install_tree,
    )
    return [
        DefaultInfo(
            files = depset([install_tree]),
            runfiles = ctx.runfiles(files = [install_tree]),
        ),
        PyInfo(
            imports = depset([site_packages]),
            transitive_pyi_files = depset(),
            transitive_sources = depset([install_tree]),
            virtual_dependencies = depset(),
            virtual_resolutions = depset(),
        ),
        PyWheelsInfo(wheels = depset([wheel])),
    ]

fixture_wheel = rule(
    implementation = _fixture_wheel_impl,
    doc = "An installed wheel whose layout metadata is derived like a uv wheel's.",
    attrs = {
        "distribution": attr.string(mandatory = True),
        "files": attr.string_dict(
            doc = "site-packages-relative path -> file content.",
            mandatory = True,
        ),
    },
    toolchains = [PY_TOOLCHAIN],
)
