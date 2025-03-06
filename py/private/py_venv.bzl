"""Create a Python virtualenv directory structure.

Note that [py_binary](./py_binary.md#py_binary) and [py_test](./py_test.md#py_test) macros automatically provide `[name].venv` targets.
Using `py_venv` directly is only required for cases where those defaults do not apply.

> [!NOTE]
> As an implementation detail, this currently uses <https://github.com/prefix-dev/rip> which is a very fast Rust-based tool.
"""

load("@aspect_bazel_lib//lib:paths.bzl", "BASH_RLOCATION_FUNCTION", "to_rlocation_path")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("@rules_python//python:defs.bzl", "PyInfo")
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
            "{{ARG_COLLISION_STRATEGY}}": ctx.attr.package_collisions,
            "{{ARG_VENV_LOCATION}}": paths.join(ctx.attr.location, ctx.attr.venv_name),
            "{{ARG_VENV_NAME}}": ".{}.venv".format(ctx.attr.name),
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
        ],
        extra_runfiles_depsets = [
            ctx.attr._runfiles_lib[DefaultInfo].default_runfiles,
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

py_venv_rule = rule(
    doc = """Create a Python virtual environment with the dependencies listed.""",
    implementation = _py_venv_rule_imp,
    attrs = {
        "deps": attr.label_list(
            doc = "Targets that produce Python code, commonly `py_library` rules.",
            allow_files = True,
            providers = [[PyInfo], [PyVirtualInfo]],
        ),
        "data": attr.label_list(
            doc = """Runtime dependencies of the program.

        The transitive closure of the `data` dependencies will be available in the `.runfiles`
        folder for this binary/test. The program may optionally use the Runfiles lookup library to
        locate the data files, see https://pypi.org/project/bazel-runfiles/.
        """,
            allow_files = True,
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
            doc = """Satisfy a virtual_dep with a mapping from external package name to the label of an installed package that provides it.
            See [virtual dependencies](/docs/virtual_deps.md).""",
        ),
        "package_collisions": attr.string(
            doc = """The action that should be taken when a symlink collision is encountered when creating the venv.
A collision can occur when multiple packages providing the same file are installed into the venv. The possible values are:

* "error": When conflicting symlinks are found, an error is reported and venv creation halts.
* "warning": When conflicting symlinks are found, an warning is reported, however venv creation continues.
* "ignore": When conflicting symlinks are found, no message is reported and venv creation continues.
            """,
            default = "error",
            values = ["error", "warning", "ignore"],
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
    """Wrapper macro for [`py_venv_rule`](#py_venv_rule).

    Chooses a suitable default location for the resulting directory.

    By default, VSCode (and likely other tools) expect to find virtualenv's in the root of the project opened in the editor.
    They also provide a nice name to see "which one is open" when discovered this way.
    See https://github.com/aspect-build/rules_py/issues/395

    Use py_venv_rule directly to have more control over the location.
    """
    default_venv_name = ".{}".format(paths.join(native.package_name(), name).replace("/", "+"))
    py_venv_rule(
        name = name,
        venv_name = kwargs.pop("venv_name", default_venv_name),
        **kwargs
    )
