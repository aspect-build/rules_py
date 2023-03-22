"""
Bazel rules to handle building virtualenvs for py_binary/py_test scripts.
Uses .pth files to allow linking each virtualenv to already installed external
repos from bazelbuild/rules_python (or any other py_library rule, really)
"""

load("@aspect_bazel_lib//lib:paths.bzl", "BASH_RLOCATION_FUNCTION", "to_manifest_path")
load("//py/private:providers.bzl", "PyWheelInfo")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:utils.bzl", "PY_TOOLCHAIN", "SH_TOOLCHAIN", "resolve_toolchain")

def _wheel_path_map(file):
    return file.path

def _get_attr(ctx, attr, override):
    if override == None and hasattr(ctx, attr):
        return getattr(ctx, attr)
    else:
        return override

def _make_venv(ctx, name = None, main = None):
    bash_bin = ctx.toolchains[SH_TOOLCHAIN].path
    interpreter = resolve_toolchain(ctx)

    name = _get_attr(ctx.attr, "name", name)

    # Get each path to every wheel we need, this includes the transitive wheels
    # As these are just filegroups, then we need to dig into the default_runfiles to get the transitive files
    # Create a depset for all these
    wheels_depsets = [
        target[PyWheelInfo].files
        for target in ctx.attr.deps
        if PyWheelInfo in target
    ]
    wheels_depset = depset(
        transitive = wheels_depsets,
    )

    # To avoid calling to_list, and then either creating a lot of extra symlinks or adding a large number
    # of find-links flags to pip, we can create a conf file and add a file-links section.
    # Create this via the an args action so we can work directly with the depset
    whl_requirements = ctx.actions.declare_file("%s.requirements.txt" % name)

    whl_requirements_lines = ctx.actions.args()

    # Note the format here is set to multiline so that each line isn't shell quoted
    whl_requirements_lines.set_param_file_format(format = "multiline")
    whl_requirements_lines.add_all(wheels_depset, map_each = _wheel_path_map)

    ctx.actions.write(
        output = whl_requirements,
        content = whl_requirements_lines,
    )

    # Create a depset from the `imports` depsets, then pass this to Args to create the `.pth` file.
    # This avoids having to call `.to_list` on the depset and taking the perf hit.
    # We also need to collect our own "imports" attr.
    # Can reuse the helper from py_library, as it's the same process
    imports_depset = _py_library.make_imports_depset(ctx)

    pth = ctx.actions.declare_file("%s.pth" % name)

    pth_lines = ctx.actions.args()

    pth_lines.add_all(imports_depset)

    ctx.actions.write(
        output = pth,
        content = pth_lines,
    )

    venv_directory = ctx.actions.declare_directory("%s.source" % name)

    common_substitutions = {
        "{{BASH_BIN}}": bash_bin,
        "{{BASH_RLOCATION_FN}}": BASH_RLOCATION_FUNCTION,
        "{{BAZEL_WORKSPACE_NAME}}": ctx.workspace_name,
        "{{INTERPRETER_FLAGS}}": " ".join(interpreter.flags),
        "{{INSTALL_WHEELS}}": str(len(wheels_depsets) > 0).lower(),
        "{{WHL_REQUIREMENTS_FILE}}": whl_requirements.path,
        "{{PTH_FILE}}": pth.path,
        "{{PYTHON_INTERPRETER_PATH}}": interpreter.python.path,
        "{{VENV_LOCATION}}": venv_directory.path,
        "{{USE_MANIFEST_PATH}}": "false",
    }

    make_venv_for_action_sh = ctx.actions.declare_file(name + "_venv.sh")
    ctx.actions.expand_template(
        template = ctx.file._venv_tmpl,
        output = make_venv_for_action_sh,
        substitutions = common_substitutions,
        is_executable = True,
    )

    make_venv_for_ide_sh = ctx.actions.declare_file("%s_create_venv.sh" % name)
    ctx.actions.expand_template(
        template = ctx.file._venv_tmpl,
        output = make_venv_for_ide_sh,
        substitutions = dict(
            common_substitutions,
            **{
                "{{WHL_REQUIREMENTS_FILE}}": to_manifest_path(ctx, whl_requirements),
                "{{PTH_FILE}}": to_manifest_path(ctx, pth),
                "{{VENV_LOCATION}}": "${BUILD_WORKSPACE_DIRECTORY}/.%s" % name,
                "{{USE_MANIFEST_PATH}}": "true",
            }
        ),
        is_executable = True,
    )

    venv_creation_depset = depset(
        direct = [make_venv_for_action_sh, pth, whl_requirements],
        transitive = [wheels_depset, interpreter.files],
    )

    ctx.actions.run_shell(
        outputs = [venv_directory],
        inputs = venv_creation_depset,
        command = make_venv_for_action_sh.path,
        tools = [
            interpreter.files,
        ],
        progress_message = "Creating virtual environment for %{label}",
        mnemonic = "CreateVenv",
    )

    return struct(
        venv_directory = venv_directory,
        make_venv_for_action_sh = make_venv_for_action_sh,
        make_venv_for_ide_sh = make_venv_for_ide_sh,
        venv_creation_depset = venv_creation_depset,
    )

def _py_venv_impl(ctx):
    interpreter = resolve_toolchain(ctx)
    venv_info = _make_venv(ctx)

    runfiles = _py_library.make_merged_runfiles(
        ctx,
        extra_depsets = [
            venv_info.venv_creation_depset,
            interpreter.files,
        ],
        extra_runfiles = ctx.files._runfiles_lib,
        extra_runfiles_depsets = [
            target[PyWheelInfo].default_runfiles
            for target in ctx.attr.deps
            if PyWheelInfo in target
        ],
    )

    return [
        DefaultInfo(
            files = depset([
                venv_info.make_venv_for_ide_sh,
            ]),
            runfiles = runfiles,
            executable = venv_info.make_venv_for_ide_sh,
        ),
    ]

_common_attrs = dict({
    "_venv_tmpl": attr.label(
        allow_single_file = True,
        default = "//py/private/venv:venv.tmpl.sh",
    ),
    "_runfiles_lib": attr.label(
        default = "@bazel_tools//tools/bash/runfiles",
    ),
})

_toolchains = [
    SH_TOOLCHAIN,
    PY_TOOLCHAIN,
]

_attrs = dict(**_common_attrs)
_attrs.update(**_py_library.attrs)

py_venv = rule(
    implementation = _py_venv_impl,
    attrs = _attrs,
    toolchains = _toolchains,
    executable = True,
)

py_venv_utils = struct(
    attrs = _common_attrs,
    toolchains = _toolchains,
    make_venv = _make_venv,
)
