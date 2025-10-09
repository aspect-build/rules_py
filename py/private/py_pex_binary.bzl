"""Create a zip file containing a full Python application.

Follows [PEP-441 (PEX)](https://peps.python.org/pep-0441/)

## Ensuring a compatible interpreter is used

The resulting zip file does *not* contain a Python interpreter.
Users are expected to execute the PEX with a compatible interpreter on the runtime system.

Use the `python_interpreter_constraints` to provide an error if a wrong interpreter tries to execute the PEX, for example:

```starlark
py_pex_binary(
    python_interpreter_constraints = [
        "CPython=={major}.{minor}.{patch}",
    ]
)
```
"""

load("@rules_python//python:defs.bzl", "PyInfo")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")

def _runfiles_path(file, workspace):
    if file.short_path.startswith("../"):
        return file.short_path[3:]
    else:
        return workspace + "/" + file.short_path

exclude_paths = [
    # following two lines will match paths we want to exclude in non-bzlmod setup
    "toolchain",
    "aspect_rules_py/py/tools/",
    # these will match in bzlmod setup
    "rules_python~~python~",
    "aspect_rules_py~/py/tools/",
    # these will match in bzlmod setup with --incompatible_use_plus_in_repo_names flag flipped.
    "rules_python++python+",
    "aspect_rules_py+/py/tools/",
]

# determines if the given file is a `distinfo`, `dep` or a `source`
# this required to allow PEX to put files into different places.
#
# --dep:        into `<PEX_UNPACK_ROOT>/.deps/<name_of_the_package>`
# --distinfo:   is only used for determining package metadata
# --source:     into `<PEX_UNPACK_ROOT>/<relative_path_to_workspace_root>/<file_name>`
def _map_srcs(f, workspace):
    dest_path = _runfiles_path(f, workspace)

    # We exclude files from hermetic python toolchain.
    for exclude in exclude_paths:
        if dest_path.find(exclude) != -1:
            return []

    site_packages_i = f.path.find("site-packages")

    # If the path contains 'site-packages', treat it as a third party dep
    if site_packages_i != -1:
        if f.path.find("dist-info", site_packages_i) != -1 and f.path.count("/", site_packages_i) == 2:
            return ["--distinfo={}".format(f.dirname)]

        return ["--dep={}".format(f.path[:site_packages_i + len("site-packages")])]

    # If the path does not have a `site-packages` in it, then put it into the standard runfiles tree.
    return ["--source={}={}".format(f.path, dest_path)]

def _py_python_pex_impl(ctx):
    py_toolchain = _py_semantics.resolve_toolchain(ctx)

    binary = ctx.attr.binary
    runfiles = binary[DefaultInfo].data_runfiles

    output = ctx.actions.declare_file(ctx.attr.name + ".pex")

    args = ctx.actions.args()

    args.use_param_file(param_file_arg = "@%s")
    args.set_param_file_format("multiline")

    # Copy workspace name here to prevent ctx
    # being transferred to the execution phase.
    workspace_name = str(ctx.workspace_name)

    args.add_all(
        ctx.attr.inject_env.items(),
        map_each = lambda e: "--inject-env={}={}".format(e[0], e[1]),
        # this is needed to allow passing a lambda to map_each
        allow_closure = True,
    )

    args.add_all(
        binary[PyInfo].imports,
        format_each = "--sys-path=%s",
    )

    args.add_all(
        runfiles.files,
        map_each = lambda f: _map_srcs(f, workspace_name),
        uniquify = True,
        # this is needed to allow passing a lambda (with workspace_name) to map_each
        allow_closure = True,
    )
    args.add(binary[DefaultInfo].files_to_run.executable, format = "--executable=%s")
    args.add(ctx.attr.python_shebang, format = "--python-shebang=%s")

    py_version = py_toolchain.interpreter_version_info
    args.add_all(
        [
            constraint.format(major = py_version.major, minor = py_version.minor, patch = py_version.micro)
            for constraint in ctx.attr.python_interpreter_constraints
        ],
        format_each = "--python-version-constraint=%s",
    )
    args.add(output, format = "--output-file=%s")

    ctx.actions.run(
        executable = ctx.executable._pex,
        inputs = runfiles.files,
        arguments = [args],
        outputs = [output],
        mnemonic = "PyPex",
        progress_message = "Building PEX binary %{label}",
    )

    return [
        DefaultInfo(files = depset([output]), executable = output),
    ]

_attrs = dict({
    "binary": attr.label(executable = True, cfg = "target", mandatory = True, doc = "A py_binary target"),
    "inject_env": attr.string_dict(
        doc = "Environment variables to set when running the pex binary.",
        default = {},
    ),
    "python_shebang": attr.string(default = "#!/usr/bin/env python3"),
    "python_interpreter_constraints": attr.string_list(
        default = ["CPython=={major}.{minor}.*"],
        doc = """\
Python interpreter versions this PEX binary is compatible with. A list of semver strings. 
The placeholder strings `{major}`, `{minor}`, `{patch}` can be used for gathering version 
information from the hermetic python toolchain.
""",
    ),
    # NB: this is read by _resolve_toolchain in py_semantics.
    "_interpreter_version_flag": attr.label(
        default = "//py:interpreter_version",
    ),
    "_pex": attr.label(executable = True, cfg = "exec", default = "//py/tools/pex"),
})

py_pex_binary = rule(
    doc = "Build a pex executable from a py_binary",
    implementation = _py_python_pex_impl,
    attrs = _attrs,
    toolchains = [
        PY_TOOLCHAIN,
    ],
    executable = True,
)
