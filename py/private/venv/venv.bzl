"Implementations for the py_venv rule."

load("@aspect_bazel_lib//lib:paths.bzl", "BASH_RLOCATION_FUNCTION", "to_manifest_path")
load("//py/private:providers.bzl", "PyWheelInfo")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:utils.bzl", "COREUTILS_TOOLCHAIN", "PY_TOOLCHAIN", "SH_TOOLCHAIN", "resolve_toolchain")

def _wheel_path_map(file):
    return file.path

def _pth_import_line_map(line):
    # Strip the leading workspace name off the import
    return "/".join(line.split("/")[1:])

def _get_attr(ctx, attr, override):
    if override == None and hasattr(ctx, attr):
        return getattr(ctx, attr)
    else:
        return override

def _make_venv(ctx, name = None, strip_pth_workspace_root = None):
    bash_bin = ctx.toolchains[SH_TOOLCHAIN].path
    interpreter = resolve_toolchain(ctx)

    name = _get_attr(ctx.attr, "name", name)
    strip_pth_workspace_root = _get_attr(ctx.attr, "strip_pth_workspace_root", strip_pth_workspace_root)

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

    # The venv is created at the root of the runfiles tree, in 'VENV_NAME', the full path is "${RUNFILES_DIR}/${VENV_NAME}",
    # but depending on if we are running as the top level binary or a tool, then $RUNFILES_DIR may be absolute or relative.
    # Paths in the .pth are relative to the site-packages folder where they reside.
    # All "import" paths from `py_library` start with the workspace name, so we need to go back up the tree for
    # each segment from site-packages in the venv to the root of the runfiles tree.
    # Four .. will get us back to the root of the venv:
    # {name}.runfiles/.{name}.venv/lib/python{version}/site-packages/first_party.pth
    escape = "/".join(([".."] * 4))
    pth_add_all_kwargs = dict({
        "format_each": escape + "/%s",
    })

    # If we are creating a venv for an IDE we likely don't have a workspace folder at with everything inside, so strip
    # this from the import paths.
    # We can't pass variables to the map_each functions, so conditionally add it instead.
    if strip_pth_workspace_root:
        pth_add_all_kwargs.update({
            "map_each": _pth_import_line_map,
        })

    # A few imports rely on being able to reference the root of the runfiles tree as a Python module,
    # the common case here being the @rules_python//python/runfiles target that adds the runfiles helper,
    # which ends up in bazel_tools/tools/python/runfiles/runfiles.py, but there are no imports attrs that hint we
    # should be adding the root to the PYTHONPATH
    # Maybe in the future we can opt out of this?
    pth_lines.add(escape)

    pth_lines.add_all(
        imports_depset,
        **pth_add_all_kwargs
    )

    ctx.actions.write(
        output = pth,
        content = pth_lines,
    )

    coreutils = ctx.toolchains[COREUTILS_TOOLCHAIN]
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
        "{{COREUTILS_BIN}}": coreutils.coreutils_info.bin.path,
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
                "{{PYTHON_INTERPRETER_PATH}}": to_manifest_path(ctx, interpreter.python),
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
            ctx.attr._coreutils_toolchain.files_to_run,
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
    COREUTILS_TOOLCHAIN,
    PY_TOOLCHAIN,
    SH_TOOLCHAIN,
]

_attrs = dict({
    "strip_pth_workspace_root": attr.bool(
        default = True,
    ),
})

_attrs.update(**_common_attrs)
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
