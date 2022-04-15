"Implementation for the py_binary and py_test rules."

load("@aspect_bazel_lib//lib:paths.bzl", "BASH_RLOCATION_FUNCTION", "to_manifest_path")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:utils.bzl", "dict_to_exports")

PY_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"
SH_TOOLCHAIN = "@bazel_tools//tools/sh:toolchain_type"

def _strip_external(path):
    return path[len("external/"):] if path.startswith("external/") else path

def _wheel_path_map(file):
    return file.short_path

def _resolve_toolchain(ctx):
    toolchain_info = ctx.toolchains[PY_TOOLCHAIN]

    if not toolchain_info.py3_runtime:
        fail("A py3_runtime must be set on the Python toolchain")

    py3_toolchain = toolchain_info.py3_runtime

    interpreter_path = None
    if py3_toolchain.interpreter_path:
        interpreter_path = py3_toolchain.interpreter_path
    else:
        interpreter_path = to_manifest_path(ctx, py3_toolchain.interpreter)

    if interpreter_path == None:
        fail("Unable to resolve a path to the Python interperter")

    return struct(
        toolchain = py3_toolchain,
        path = interpreter_path,
        flags = ["-B", "-s", "-I"],
    )

def _py_binary_rule_imp(ctx):
    bash_bin = ctx.toolchains[SH_TOOLCHAIN].path
    interpreter = _resolve_toolchain(ctx)
    main = ctx.file.main

    runfiles_files = [] + ctx.files._runfiles_lib

    entry = ctx.actions.declare_file(ctx.attr.name)
    env = dict({
        "BAZEL_TARGET": ctx.label,
        "BAZEL_WORKSPACE": ctx.workspace_name,
        "BAZEL_TARGET_NAME": ctx.attr.name,
    }, **ctx.attr.env)

    # Get each path to every wheel we need, this includes the transitive wheels
    # As these are just filegroups, then we need to dig into the default_runfiles to get the transitive files
    # Create a depset for all these
    wheels_depsets = []
    for target in ctx.attr.wheels:
        wheels_depsets.append(target[DefaultInfo].files)
        wheels_depsets.append(target[DefaultInfo].default_runfiles.files)

    wheels_depset = depset(
        transitive = wheels_depsets,
    )

    # To avoid calling to_list, and then either creating a lot of extra symlinks or adding a large number
    # of find-links flags to pip, we can create a conf file and add a file-links section.
    # Create this via the an args action so we can work directly with the depset
    pip_find_links_sh = ctx.actions.declare_file("%s.pip.conf.sh" % ctx.attr.name)
    runfiles_files.append(pip_find_links_sh)

    find_links_lines = ctx.actions.args()

    # Note the format here is set to multiline so that each line isn't shell quoted
    find_links_lines.set_param_file_format(format = "multiline")

    find_links_lines.add("#!%s" % bash_bin)
    find_links_lines.add_all(wheels_depset, map_each = _wheel_path_map, format_each = "echo $(wheel_location %s)")

    ctx.actions.write(
        output = pip_find_links_sh,
        content = find_links_lines,
    )

    # Create a depset from the `imports` depsets, then pass this to Args to create the `.pth` file.
    # This avoids having to call `.to_list` on the depset and taking the perf hit.
    # We also need to collect our own "imports" attr.
    # Can reuse the helper from py_library, as it's the same process
    imports_depset = _py_library.make_imports_depset(ctx)

    pth = ctx.actions.declare_file("%s.pth" % ctx.attr.name)
    runfiles_files.append(pth)

    pth_lines = ctx.actions.args()

    # The venv is created at the root of the runfiles tree, in 'VENV_NAME', the full path is "${RUNFILES_DIR}/${VENV_NAME}",
    # but depending on if we are running as the top level binary or a tool, then $RUNFILES_DIR may be absolute or relative.
    # Paths in the .pth are relative to the site-packages folder where they reside.
    # All "import" paths from `py_library` start with the workspace name, so we need to go back up the tree for
    # each segment from site-packages in the venv to the root of the runfiles tree.
    # Four .. will get us back to the root of the venv:
    # {name}.runfiles/.{name}.venv/lib/python{version}/site-packages/first_party.pth
    escape = ([".."] * 4)
    pth_lines.add_all(imports_depset, format_each = "/".join(escape) + "/%s")

    ctx.actions.write(
        output = pth,
        content = pth_lines,
    )

    common_substitutions = {
        "{{BASH_BIN}}": bash_bin,
        "{{BASH_RLOCATION_FN}}": BASH_RLOCATION_FUNCTION,
        "{{BAZEL_WORKSPACE_NAME}}": ctx.workspace_name,
        "{{BINARY_ENTRY_POINT}}": to_manifest_path(ctx, main),
        "{{INTERPRETER_FLAGS}}": " ".join(interpreter.flags),
        "{{INTERPRETER_FLAGS_PARTS}}": " ".join(['"%s", ' % f for f in interpreter.flags]),
        "{{INSTALL_WHEELS}}": str(len(ctx.attr.wheels) > 0).lower(),
        "{{PIP_FIND_LINKS_SH}}": to_manifest_path(ctx, pip_find_links_sh),
        "{{PTH_FILE}}": to_manifest_path(ctx, pth),
        "{{PYTHON_INTERPRETER_PATH}}": interpreter.path,
        "{{RUN_BINARY_ENTRY_POINT}}": "true",
        "{{VENV_NAME}}": ".%s.venv" % ctx.attr.name,
        "{{VENV_LOCATION}}": "${RUNFILES_VENV_LOCATION}",
        "{{PYTHON_ENV}}": "\n".join(dict_to_exports(env)).strip(),
        "{{PYTHON_ENV_UNSET}}": "\n".join(["unset %s" % k for k in env.keys()]).strip(),
    }

    ctx.actions.expand_template(
        template = ctx.file._entry,
        output = entry,
        substitutions = common_substitutions,
        is_executable = True,
    )

    create_venv_bin = ctx.actions.declare_file("%s_create_venv.sh" % ctx.attr.name)
    ctx.actions.expand_template(
        template = ctx.file._entry,
        output = create_venv_bin,
        substitutions = dict(
            common_substitutions,
            **{
                "{{RUN_BINARY_ENTRY_POINT}}": "false",
                "{{VENV_LOCATION}}": "${BUILD_WORKSPACE_DIRECTORY}/$@",
            }
        ),
        is_executable = True,
    )

    srcs_depset = _py_library.make_srcs_depset(ctx)

    runfiles = _py_library.make_merged_runfiles(
        ctx,
        extra_depsets = [
            interpreter.toolchain.files,
            wheels_depset,
            srcs_depset,
        ],
        extra_runfiles = runfiles_files,
        extra_runfiles_depsets = [
            target[DefaultInfo].default_runfiles
            for target in ctx.attr.wheels
        ],
    )

    return [
        DefaultInfo(
            files = depset([entry, main]),
            runfiles = runfiles,
            executable = entry,
        ),
        OutputGroupInfo(
            create_venv = [create_venv_bin],
        ),
        # Return PyInfo?
    ]

py_base = struct(
    implementation = _py_binary_rule_imp,
    attrs = dict({
        "env": attr.string_dict(
            default = {},
        ),
        "wheels": attr.label_list(
            allow_files = [".whl"],
        ),
        "main": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "_entry": attr.label(
            allow_single_file = True,
            default = "//py/private:entry.tmpl.sh",
        ),
        "_runfiles_lib": attr.label(
            default = "@bazel_tools//tools/bash/runfiles",
        ),
    }, **_py_library.attrs),
    toolchains = [
        SH_TOOLCHAIN,
        PY_TOOLCHAIN,
    ],
)

py_binary = rule(
    implementation = py_base.implementation,
    attrs = py_base.attrs,
    toolchains = py_base.toolchains,
    executable = True,
)

py_test = rule(
    implementation = py_base.implementation,
    attrs = py_base.attrs,
    toolchains = py_base.toolchains,
    test = True,
)
