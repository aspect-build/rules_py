"""Implementation for the py_binary and py_test rules."""

load("@rules_python//python:defs.bzl", "PyInfo")
load("@aspect_bazel_lib//lib:paths.bzl", "BASH_RLOCATION_FUNCTION", "to_rlocation_path")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("//py/private:providers.bzl", "PyVirtualInfo")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "VENV_TOOLCHAIN")

def _py_venv_rule_imp(ctx):
    venv_toolchain = ctx.toolchains[VENV_TOOLCHAIN]
    py_toolchain = _py_semantics.resolve_toolchain(ctx)

    virtual_resolution = _py_library.resolve_virtuals(ctx)

    # Create the .pth file.
    imports_depset = _py_library.make_imports_depset(ctx, extra_imports_depsets = virtual_resolution.imports)

    pth_lines = ctx.actions.args()
    pth_lines.use_param_file("%s", use_always = True)
    pth_lines.set_param_file_format("multiline")

    # A few imports rely on being able to reference the root of the runfiles tree as a Python module,
    # the common case here being the @rules_python//python/runfiles target that adds the runfiles helper,
    # which ends up in bazel_tools/tools/python/runfiles/runfiles.py, but there are no imports attrs that hint we
    # should be adding the root to the PYTHONPATH
    # Maybe in the future we can opt out of this?
    pth_lines.add(".")

    pth_lines.add_all(imports_depset)

    site_packages_pth_file = ctx.actions.declare_file("{}.venv.pth".format(ctx.attr.name))
    ctx.actions.write(
        output = site_packages_pth_file,
        content = pth_lines,
    )

    executable_launcher = ctx.actions.declare_file(ctx.attr.name)
    ctx.actions.expand_template(
        template = ctx.file._venv_tmpl,
        output = executable_launcher,
        substitutions = {
            "{{BASH_RLOCATION_FN}}": BASH_RLOCATION_FUNCTION,
            "{{INTERPRETER_FLAGS}}": " ".join(py_toolchain.flags),
            "{{VENV_TOOL}}": to_rlocation_path(ctx, venv_toolchain.bin),
            "{{ARG_PYTHON}}": to_rlocation_path(ctx, py_toolchain.python) if py_toolchain.runfiles_interpreter else py_toolchain.python.path,
            "{{ARG_VENV_LOCATION}}": paths.join(ctx.attr.location, ctx.attr.venv_name),
            "{{ARG_VENV_PYTHON_VERSION}}": "{}.{}.{}".format(
                py_toolchain.interpreter_version_info.major,
                py_toolchain.interpreter_version_info.minor,
                py_toolchain.interpreter_version_info.micro,
            ),
            "{{ARG_PTH_FILE}}": to_rlocation_path(ctx, site_packages_pth_file),
            "{{EXEC_PYTHON_BIN}}": "python{}".format(
                py_toolchain.interpreter_version_info.major,
            ),
            "{{RUNFILES_INTERPRETER}}": str(py_toolchain.runfiles_interpreter).lower(),
        },
        is_executable = True,
    )

    runfiles = _py_library.make_merged_runfiles(
        ctx,
        extra_depsets = [
            py_toolchain.files,
        ] + virtual_resolution.srcs + virtual_resolution.runfiles,
        extra_runfiles = [
            site_packages_pth_file,
        ] + ctx.files._runfiles_lib,
        extra_runfiles_depsets = [
            venv_toolchain.default_info.default_runfiles,
        ],
    )

    return [
        DefaultInfo(
            files = depset([
                executable_launcher,
                site_packages_pth_file,
            ]),
            executable = executable_launcher,
            runfiles = runfiles,
        ),
    ]

_py_venv = rule(
    doc = "Create a Python virtual environment with the dependencies listed.",
    implementation = _py_venv_rule_imp,
    attrs = {
        "deps": attr.label_list(
            doc = "Targets that produce Python code, commonly `py_library` rules.",
            allow_files = True,
            providers = [[PyInfo], [PyVirtualInfo]],
        ),
        "imports": attr.string_list(
            doc = "List of import directories to be added to the PYTHONPATH.",
            default = [],
        ),
        "location": attr.string(
            doc = "Path from the workspace root for where to root the virtial environment",
            mandatory = False,
        ),
        "venv_name": attr.string(
            doc = "Outer folder name for the generated virtual environment",
            mandatory = False,
        ),
        "resolutions": attr.label_keyed_string_dict(
            doc = "FIXME",
        ),
        "_venv_tmpl": attr.label(
            allow_single_file = True,
            default = "//py/private:venv.tmpl.sh",
        ),
        "_runfiles_lib": attr.label(
            default = "@bazel_tools//tools/bash/runfiles",
        ),
        # NB: this is read by _resolve_toolchain in py_semantics.
        "_interpreter_version_flag": attr.label(
            default = "//py:interpreter_version",
        ),
    },
    toolchains = [
        PY_TOOLCHAIN,
        VENV_TOOLCHAIN,
    ],
    executable = True,
)

def py_venv(name, **kwargs):
    _py_venv(
        name = name,
        location = kwargs.pop("location", native.package_name()),
        venv_name = kwargs.pop("venv_name", ".{}".format(name)),
        **kwargs
    )
