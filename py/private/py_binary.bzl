"""Implementation for the py_binary and py_test rules."""

load("@aspect_bazel_lib//lib:paths.bzl", "BASH_RLOCATION_FUNCTION", "to_rlocation_path")
load("@aspect_bazel_lib//lib:expand_make_vars.bzl", "expand_locations", "expand_variables")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "SH_TOOLCHAIN", "VENV_TOOLCHAIN")

_MUST_SET_INTERPRETER_VERSION_FLAG = """\
ERROR: Prior to Bazel 7.x, the python interpreter version must be explicitly provided.

For example in `.bazelrc` with Bazel 6.4, add
        
    common --@aspect_rules_py//py:interpreter_version=3.9.18

Bazel 6.3 and earlier didn't handle the `common` verb for custom flags.
Repeat the flag to avoid discarding the analysis cache:

    build --@aspect_rules_py//py:interpreter_version=3.9.18
    fetch --@aspect_rules_py//py:interpreter_version=3.9.18
    query --@aspect_rules_py//py:interpreter_version=3.9.18
"""

def _dict_to_exports(env):
    return [
        "export %s=\"%s\"" % (k, v)
        for (k, v) in env.items()
    ]

def _py_binary_rule_impl(ctx):
    sh_toolchain = ctx.toolchains[SH_TOOLCHAIN]
    venv_toolchain = ctx.toolchains[VENV_TOOLCHAIN]
    py_toolchain = _py_semantics.resolve_toolchain(ctx)

    # Check for duplicate virtual dependency names. Those that map to the same resolution target would have been merged by the depset for us.
    virtual_resolution = _py_library.resolve_virtuals(ctx)
    imports_depset = _py_library.make_imports_depset(ctx, extra_imports_depsets = virtual_resolution.imports)

    pth_lines = ctx.actions.args()
    pth_lines.use_param_file("%s", use_always = True)
    pth_lines.set_param_file_format("multiline")

    # The venv is created at the root in the runfiles tree, in 'VENV_NAME', the full path is "${RUNFILES_DIR}/${VENV_NAME}",
    # but depending on if we are running as the top level binary or a tool, then $RUNFILES_DIR may be absolute or relative.
    # Paths in the .pth are relative to the site-packages folder where they reside.
    # All "import" paths from `py_library` start with the workspace name, so we need to go back up the tree for
    # each segment from site-packages in the venv to the root of the runfiles tree.
    # Five .. will get us back to the root of the venv:
    # {name}.runfiles/.{name}.venv/lib/python{version}/site-packages/first_party.pth
    escape = "/".join(([".."] * 4))

    # A few imports rely on being able to reference the root of the runfiles tree as a Python module,
    # the common case here being the @rules_python//python/runfiles target that adds the runfiles helper,
    # which ends up in bazel_tools/tools/python/runfiles/runfiles.py, but there are no imports attrs that hint we
    # should be adding the root to the PYTHONPATH
    # Maybe in the future we can opt out of this?
    pth_lines.add(escape)

    pth_lines.add_all(imports_depset, format_each = "{}/%s".format(escape))

    site_packages_pth_file = ctx.actions.declare_file("{}.venv.pth".format(ctx.attr.name))
    ctx.actions.write(
        output = site_packages_pth_file,
        content = pth_lines,
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

    if "interpreter_version_info" in dir(py_toolchain.toolchain):
        major = py_toolchain.toolchain.interpreter_version_info.major
        minor = py_toolchain.toolchain.interpreter_version_info.minor
        micro = py_toolchain.toolchain.interpreter_version_info.micro
    elif ctx.attr._interpreter_version_flag[BuildSettingInfo].value:
        # Same code as rules_python:
        # https://github.com/bazelbuild/rules_python/blob/76f1c76f60ccb536d3b3e2c9f023d8063f40bcd5/python/repositories.bzl#L109
        major, minor, micro = ctx.attr._interpreter_version_flag[BuildSettingInfo].value.split(".")
    else:
        fail(_MUST_SET_INTERPRETER_VERSION_FLAG)

    executable_launcher = ctx.actions.declare_file(ctx.attr.name)
    ctx.actions.expand_template(
        template = ctx.file._run_tmpl,
        output = executable_launcher,
        substitutions = {
            "{{SHELL_BIN}}": sh_toolchain.path,
            "{{BASH_RLOCATION_FN}}": BASH_RLOCATION_FUNCTION,
            "{{INTERPRETER_FLAGS}}": " ".join(py_toolchain.flags),
            "{{VENV_TOOL}}": to_rlocation_path(ctx, venv_toolchain.bin),
            "{{ARG_PYTHON}}": to_rlocation_path(ctx, py_toolchain.python),
            "{{ARG_VENV_NAME}}": ".{}.venv".format(ctx.attr.name),
            "{{ARG_VENV_PYTHON_VERSION}}": "{}.{}.{}".format(
                major,
                minor,
                micro,
            ),
            "{{ARG_PTH_FILE}}": to_rlocation_path(ctx, site_packages_pth_file),
            "{{ENTRYPOINT}}": to_rlocation_path(ctx, ctx.file.main),
            "{{PYTHON_ENV}}": "\n".join(_dict_to_exports(env)).strip(),
            "{{EXEC_PYTHON_BIN}}": "python{}".format(major),
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
        ] + ctx.files._runfiles_lib,
        extra_runfiles_depsets = [
            venv_toolchain.default_info.default_runfiles,
        ],
    )

    instrumented_files_info = _py_library.make_instrumented_files_info(
        ctx,
        extra_source_attributes = ["main"],
    )

    return [
        DefaultInfo(
            files = depset([
                executable_launcher,
                ctx.file.main,
                site_packages_pth_file,
            ]),
            executable = executable_launcher,
            runfiles = runfiles,
        ),
        PyInfo(
            imports = imports_depset,
            transitive_sources = srcs_depset,
            has_py2_only_sources = False,
            has_py3_only_sources = True,
            uses_shared_libraries = False,
        ),
        instrumented_files_info,
    ]

_attrs = dict({
    "env": attr.string_dict(
        doc = "Environment variables to set when running the binary.",
        default = {},
    ),
    "main": attr.label(
        doc = "Script to execute with the Python interpreter.",
        allow_single_file = True,
        mandatory = True,
    ),
    "_run_tmpl": attr.label(
        allow_single_file = True,
        default = "//py/private:run.tmpl.sh",
    ),
    "_runfiles_lib": attr.label(
        default = "@bazel_tools//tools/bash/runfiles",
    ),
    "_interpreter_version_flag": attr.label(
        default = "//py:interpreter_version",
    ),
})

_attrs.update(**_py_library.attrs)

py_base = struct(
    implementation = _py_binary_rule_impl,
    attrs = _attrs,
    toolchains = [
        SH_TOOLCHAIN,
        PY_TOOLCHAIN,
        VENV_TOOLCHAIN,
    ],
)

py_binary = rule(
    doc = "Run a Python program under Bazel. Most users should use the [py_binary macro](#py_binary) instead of loading this directly.",
    implementation = py_base.implementation,
    attrs = py_base.attrs,
    toolchains = py_base.toolchains,
    executable = True,
)

py_test = rule(
    doc = "Run a Python program under Bazel. Most users should use the [py_test macro](#py_test) instead of loading this directly.",
    implementation = py_base.implementation,
    attrs = py_base.attrs,
    toolchains = py_base.toolchains,
    test = True,
)
