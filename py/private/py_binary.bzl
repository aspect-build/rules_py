"Implementation for the py_binary and py_test rules."

load("@aspect_bazel_lib//lib:paths.bzl", "BASH_RLOCATION_FUNCTION", "to_manifest_path")
load("@aspect_bazel_lib//lib:expand_make_vars.bzl", "expand_locations", "expand_variables")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:providers.bzl", "PyWheelInfo")
load("//py/private:py_wheel.bzl", py_wheel = "py_wheel_lib")
load("//py/private:utils.bzl", "PY_TOOLCHAIN", "SH_TOOLCHAIN", "dict_to_exports", "resolve_toolchain")
load("//py/private/venv:venv.bzl", _py_venv = "py_venv_utils")

def _py_binary_rule_imp(ctx):
    bash_bin = ctx.toolchains[SH_TOOLCHAIN].path
    interpreter = resolve_toolchain(ctx)
    main = ctx.file.main

    venv_info = _py_venv.make_venv(
        ctx,
        name = "%s.venv" % ctx.attr.name,
        strip_pth_workspace_root = False,
    )

    env = dict({
        "BAZEL_TARGET": str(ctx.label).lstrip("@"),
        "BAZEL_WORKSPACE": ctx.workspace_name,
        "BAZEL_TARGET_NAME": ctx.attr.name,
    }, **ctx.attr.env)

    for k, v in env.items():
        env[k] = expand_variables(
            ctx,
            expand_locations(ctx, v, ctx.attr.data),
            attribute_name = "env",
        )

    python_interpreter_path = interpreter.python.path if interpreter.uses_interpreter_path else to_manifest_path(ctx, interpreter.python)

    common_substitutions = {
        "{{BASH_BIN}}": bash_bin,
        "{{BASH_RLOCATION_FN}}": BASH_RLOCATION_FUNCTION,
        "{{BINARY_ENTRY_POINT}}": to_manifest_path(ctx, main),
        "{{INTERPRETER_FLAGS}}": " ".join(interpreter.flags),
        "{{PYTHON_INTERPRETER_PATH}}": python_interpreter_path,
        "{{RUN_BINARY_ENTRY_POINT}}": "true",
        "{{VENV_SOURCE}}": to_manifest_path(ctx, venv_info.venv_directory),
        "{{VENV_NAME}}": "%s.venv" % ctx.attr.name,
        "{{PYTHON_ENV}}": "\n".join(dict_to_exports(env)).strip(),
        "{{PYTHON_ENV_UNSET}}": "\n".join(["unset %s" % k for k in env.keys()]).strip(),
    }

    entry = ctx.actions.declare_file(ctx.attr.name)
    ctx.actions.expand_template(
        template = ctx.file._entry,
        output = entry,
        substitutions = common_substitutions,
        is_executable = True,
    )

    srcs_depset = _py_library.make_srcs_depset(ctx)

    runfiles = _py_library.make_merged_runfiles(
        ctx,
        extra_depsets = [
            venv_info.venv_creation_depset,
            interpreter.files,
            srcs_depset,
        ],
        extra_runfiles = [
            venv_info.venv_directory,
        ] + ctx.files._runfiles_lib,
        extra_runfiles_depsets = [
            target[PyWheelInfo].default_runfiles
            for target in ctx.attr.deps
            if PyWheelInfo in target
        ],
    )

    imports = _py_library.make_imports_depset(ctx)
    instrumented_files_info = _py_library.make_instrumented_files_info(
        ctx,
        extra_source_attributes = ["main"],
    )
    py_wheel_info = py_wheel.make_py_wheel_info(ctx, ctx.attr.deps)

    return [
        DefaultInfo(
            files = depset([entry, main]),
            runfiles = runfiles,
            executable = entry,
        ),
        PyInfo(
            imports = imports,
            transitive_sources = srcs_depset,
            has_py2_only_sources = False,
            has_py3_only_sources = True,
            uses_shared_libraries = False,
        ),
        instrumented_files_info,
        py_wheel_info,
    ]

_attrs = dict({
    "env": attr.string_dict(
        default = {},
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
})

_attrs.update(**_py_venv.attrs)
_attrs.update(**_py_library.attrs)

py_base = struct(
    implementation = _py_binary_rule_imp,
    attrs = _attrs,
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
