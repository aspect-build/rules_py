"""Implementation for the py_binary and py_test rules."""

load("@rules_python//python:defs.bzl", "PyInfo")
load("@aspect_bazel_lib//lib:paths.bzl", "BASH_RLOCATION_FUNCTION", "to_rlocation_path")
load("@aspect_bazel_lib//lib:expand_make_vars.bzl", "expand_locations", "expand_variables")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "VENV_TOOLCHAIN")
load("//py/private:py_zip.bzl", "build_python_zip", "ZIP_TOOLCHAIN")

def _dict_to_exports(env):
    return [
        "export %s=\"%s\"" % (k, v)
        for (k, v) in env.items()
    ]

def _py_binary_rule_impl(ctx):
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

    executable_launcher = ctx.actions.declare_file(ctx.attr.name)
    ctx.actions.expand_template(
        template = ctx.file._run_tmpl,
        output = executable_launcher,
        substitutions = {
            "{{BASH_RLOCATION_FN}}": BASH_RLOCATION_FUNCTION,
            "{{INTERPRETER_FLAGS}}": " ".join(py_toolchain.flags),
            "{{VENV_TOOL}}": to_rlocation_path(ctx, venv_toolchain.bin),
            "{{ARG_PYTHON}}": to_rlocation_path(ctx, py_toolchain.python) if py_toolchain.runfiles_interpreter else py_toolchain.python.path,
            "{{ARG_VENV_NAME}}": ".{}.venv".format(ctx.attr.name),
            "{{ARG_VENV_PYTHON_VERSION}}": "{}.{}.{}".format(
                py_toolchain.interpreter_version_info.major,
                py_toolchain.interpreter_version_info.minor,
                py_toolchain.interpreter_version_info.micro,
            ),
            "{{ARG_PTH_FILE}}": to_rlocation_path(ctx, site_packages_pth_file),
            "{{ENTRYPOINT}}": to_rlocation_path(ctx, ctx.file.main),
            "{{PYTHON_ENV}}": "\n".join(_dict_to_exports(env)).strip(),
            "{{EXEC_PYTHON_BIN}}": "python{}".format(
                py_toolchain.interpreter_version_info.major,
            ),
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
        ] + ctx.files._runfiles_lib,
        extra_runfiles_depsets = [
            venv_toolchain.default_info.default_runfiles,
        ],
    )

    instrumented_files_info = _py_library.make_instrumented_files_info(
        ctx,
        extra_source_attributes = ["main"],
    )

    extra_default_outputs = []

    zip_output = ctx.actions.declare_file(ctx.attr.name + ".pyz", sibling = executable_launcher)
    mtree = build_python_zip(ctx, output = zip_output, runfiles = runfiles, main = ctx.file.main)

    # NOTE: --build_python_zip defauls to true on Windows
    if ctx.fragments.py.build_python_zip:
        extra_default_outputs.append(zip_output)
    
    # See: https://github.com/bazelbuild/bazel/blob/b4ab259fe1cba8a108f1dd30067ee357c7198509/src/main/starlark/builtins_bzl/common/python/py_executable_bazel.bzl#L265
    output_group_info = OutputGroupInfo(
        python_zip_file = depset([zip_output, mtree])
    )

    return [
        DefaultInfo(
            files = depset([
                executable_launcher,
                ctx.file.main,
                site_packages_pth_file,
            ] + extra_default_outputs),
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
        output_group_info,
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
    "python_version": attr.string(
        doc = """Whether to build this target and its transitive deps for a specific python version.

Note that setting this attribute alone will not be enough as the python toolchain for the desired version
also needs to be registered in the WORKSPACE or MODULE.bazel file.

When using WORKSPACE, this may look like this,

```
load("@rules_python//python:repositories.bzl", "py_repositories", "python_register_toolchains")

python_register_toolchains(
    name = "python_toolchain_3_8",
    python_version = "3.8.12",
    # setting set_python_version_constraint makes it so that only matches py_* rule  
    # which has this exact version set in the `python_version` attribute.
    set_python_version_constraint = True,
)

# It's important to register the default toolchain last it will match any py_* target. 
python_register_toolchains(
    name = "python_toolchain",
    python_version = "3.9",
)
```

Configuring for MODULE.bazel may look like this:

```
python = use_extension("@rules_python//python/extensions:python.bzl", "python")
python.toolchain(python_version = "3.8.12", is_default = False)
python.toolchain(python_version = "3.9", is_default = True)
```
"""
    ),
    "_run_tmpl": attr.label(
        allow_single_file = True,
        default = "//py/private:run.tmpl.sh",
    ),
    "_runfiles_lib": attr.label(
        default = "@bazel_tools//tools/bash/runfiles",
    ),
    # NB: this is read by _resolve_toolchain in py_semantics.
    "_interpreter_version_flag": attr.label(
        default = "//py:interpreter_version",
    ),
    # Required for py_version attribute
    "_allowlist_function_transition": attr.label(
        default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
    ),
})

_attrs.update(**_py_library.attrs)

def _python_version_transition_impl(_, attr):
    if not attr.python_version:
        return {}
    return {"@rules_python//python/config_settings:python_version": str(attr.python_version)}

_python_version_transition = transition(
    implementation = _python_version_transition_impl,
    inputs = [],
    outputs = ["@rules_python//python/config_settings:python_version"],
)

py_base = struct(
    implementation = _py_binary_rule_impl,
    attrs = _attrs,
    toolchains = [
        PY_TOOLCHAIN,
        VENV_TOOLCHAIN,
        ZIP_TOOLCHAIN
    ],
    cfg = _python_version_transition
)

py_binary = rule(
    doc = "Run a Python program under Bazel. Most users should use the [py_binary macro](#py_binary) instead of loading this directly.",
    implementation = py_base.implementation,
    attrs = py_base.attrs,
    toolchains = py_base.toolchains,
    fragments = py_base.fragments,
    executable = True,
    cfg = py_base.cfg
)

py_test = rule(
    doc = "Run a Python program under Bazel. Most users should use the [py_test macro](#py_test) instead of loading this directly.",
    implementation = py_base.implementation,
    attrs = py_base.attrs,
    toolchains = py_base.toolchains,
    fragments = py_base.fragments,
    test = True,
    cfg = py_base.cfg
)
