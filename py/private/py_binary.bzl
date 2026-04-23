"""Implementation for the py_binary and py_test rules."""

load("@bazel_lib//lib:expand_make_vars.bzl", "expand_locations", "expand_variables")
load("@bazel_lib//lib:paths.bzl", "BASH_RLOCATION_FUNCTION", "to_rlocation_path")
load("//py/private:aspect_py_info.bzl", "AspectPyInfo")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")
load(":transitions.bzl", "python_version_transition")

def _dict_to_exports(env):
    return [
        "export %s=\"%s\"" % (k, v)
        for (k, v) in env.items()
    ]

def _py_binary_impl(ctx):
    py_toolchain = _py_semantics.resolve_toolchain(ctx)
    main = _py_semantics.determine_main(ctx)

    virtual_resolution = _py_library.resolve_virtuals(ctx)
    imports_depset = _py_library.make_imports_depset(ctx, extra_imports_depsets = virtual_resolution.imports)

    # NUEVA LÓGICA: Rutas directas relativas a los runfiles, sin escapes "../"
    pth_lines = ctx.actions.args()
    pth_lines.use_param_file("%s", use_always = True)
    pth_lines.set_param_file_format("multiline")
    pth_lines.add(ctx.workspace_name)
    pth_lines.add_all(imports_depset)

    site_packages_pth_file = ctx.actions.declare_file("{}.pth".format(ctx.attr.name))
    ctx.actions.write(
        output = site_packages_pth_file,
        content = pth_lines,
    )

    default_env = {
        "BAZEL_TARGET": str(ctx.label).lstrip("@"),
        "BAZEL_WORKSPACE": ctx.workspace_name,
        "BAZEL_TARGET_NAME": ctx.attr.name,
    }

    passed_env = dict(ctx.attr.env)
    for k, v in passed_env.items():
        passed_env[k] = expand_variables(
            ctx,
            expand_locations(ctx, v, ctx.attr.data),
            attribute_name = "env",
        )

    executable_launcher = ctx.actions.declare_file(ctx.attr.name)
    ctx.actions.expand_template(
        template = ctx.file._run_tmpl,
        output = executable_launcher,
        substitutions = {
            "{{BASH_RLOCATION_FN}}": BASH_RLOCATION_FUNCTION,
            "{{INTERPRETER_FLAGS}}": " ".join(py_toolchain.flags + ctx.attr.interpreter_options),
            "{{ARG_PYTHON}}": to_rlocation_path(ctx, py_toolchain.python) if py_toolchain.runfiles_interpreter else py_toolchain.python.path,
            "{{ARG_PTH_FILE}}": to_rlocation_path(ctx, site_packages_pth_file),
            "{{ENTRYPOINT}}": to_rlocation_path(ctx, main),
            "{{PYTHON_ENV}}": "\n".join(_dict_to_exports(default_env)).strip(),
            "{{RUNFILES_INTERPRETER}}": str(py_toolchain.runfiles_interpreter).lower(),
        },
        is_executable = True,
    )

    srcs_depset = _py_library.make_srcs_depset(ctx)

    runfiles = _py_library.make_merged_runfiles(
        ctx,
        extra_depsets = [
            py_toolchain.files,
            srcs_depset,
        ] + virtual_resolution.srcs + virtual_resolution.runfiles,
        extra_runfiles = [
            site_packages_pth_file,
        ],
        extra_runfiles_depsets = [ctx.attr._runfiles_lib[DefaultInfo].default_runfiles],
    )

    instrumented_files_info = _py_library.make_instrumented_files_info(
        ctx,
        extra_source_attributes = ["main"],
    )

    return [
        DefaultInfo(
            files = depset([
                executable_launcher,
                main,
                site_packages_pth_file,
            ]),
            executable = executable_launcher,
            runfiles = runfiles,
        ),
        AspectPyInfo(
            imports = imports_depset,
            transitive_sources = srcs_depset,
            type_stubs = depset(),
            transitive_type_stubs = depset(),
            has_py2_only_sources = False,
            has_py3_only_sources = True,
            uses_shared_libraries = False,
            runfiles = runfiles,
            default_runfiles = runfiles,
            uv_metadata = None,
            transitive_uv_hashes = depset(),
            _transitive_debug_info = None,
        ),
        instrumented_files_info,
        RunEnvironmentInfo(
            environment = passed_env,
            inherited_environment = getattr(ctx.attr, "env_inherit", []),
        ),
    ]

_attrs = dict({
    "env": attr.string_dict(
        doc = "Environment variables to set when running the binary.",
        default = {},
    ),
    "main": attr.label(
        allow_single_file = True,
        doc = "Script to execute with the Python interpreter.",
    ),
    "venv": attr.string(
        doc = "The name of the Python virtual environment within which deps should be resolved.",
    ),
    "python_version": attr.string(
        doc = "Whether to build this target and its transitive deps for a specific python version.",
    ),
    "interpreter_options": attr.string_list(
        doc = "Additional options to pass to the Python interpreter.",
        default = [],
    ),
    "_run_tmpl": attr.label(
        allow_single_file = True,
        default = "//py/private:run.tmpl.sh",
    ),
    "_runfiles_lib": attr.label(
        default = "@bazel_tools//tools/bash/runfiles",
    ),
})

_attrs.update(**_py_library.attrs)

_test_attrs = dict({
    "env_inherit": attr.string_list(
        doc = "Specifies additional environment variables to inherit.",
        default = [],
    ),
    "_lcov_merger": attr.label(
        default = configuration_field(fragment = "coverage", name = "output_generator"),
        executable = True,
        cfg = "exec",
    ),
})

py_binary = rule(
    doc = "Run a Python program under Bazel.",
    implementation = _py_binary_impl,
    attrs = _attrs,
    toolchains = [PY_TOOLCHAIN],
    executable = True,
    cfg = python_version_transition,
)

py_test = rule(
    doc = "Run a Python program under Bazel test.",
    implementation = _py_binary_impl,
    attrs = _attrs | _test_attrs,
    toolchains = [PY_TOOLCHAIN],
    test = True,
    cfg = python_version_transition,
)