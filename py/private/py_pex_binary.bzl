"Create python zip file https://peps.python.org/pep-0441/ (PEX)"

load("@rules_python//python:defs.bzl", "PyInfo")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")

def _runfiles_path(file, workspace):
    if file.short_path.startswith("../"):
        return file.short_path[3:]
    else:
        return workspace + "/" + file.short_path

exclude_paths = [
    "toolchain",
    "aspect_rules_py/py/tools/",
    "rules_python~~python~",
    "aspect_rules_py~/py/tools/"
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
    
    # if path contains `site-packages` and there is only two path segments
    # after it, it will be treated as third party dep.
    # Here are some examples of path we expect and use and ones we ignore.
    #  
    # Match: `external/rules_python~~pip~pypi_39_rtoml/site-packages/rtoml-0.11.0.dist-info/INSTALLER`
    # Reason: It has two `/` after first `site-packages` substring.
    # 
    # No Match: `external/rules_python~~pip~pypi_39_rtoml/site-packages/rtoml-0.11.0/src/mod/parse.py`
    # Reason: It has three `/` after first `site-packages` substring.
    if site_packages_i != -1 and f.path.count("/", site_packages_i) == 2:
        if f.path.find("dist-info", site_packages_i) != -1:
            return ["--distinfo={}".format(f.dirname)]
        return ["--dep={}".format(f.dirname)]

    # If the path does not have a `site-packages` in it, then put it into 
    # the standard runfiles tree.
    elif site_packages_i == -1:
        return ["--source={}={}".format(f.path, dest_path)]

    return []

def _py_python_pex_impl(ctx):
    py_toolchain = _py_semantics.resolve_toolchain(ctx)

    binary = ctx.attr.binary
    runfiles = binary[DefaultInfo].data_runfiles

    output = ctx.actions.declare_file(ctx.attr.name + ".pex")

    args = ctx.actions.args()

    # Copy workspace name here to prevent ctx
    # being transferred to the execution phase.
    workspace_name = str(ctx.workspace_name)

    args.add_all(
        ctx.attr.inject_env.items(), 
        map_each = lambda e: "--inject-env=%s=%s" % (e[0], e[1]),
        allow_closure = True,
        # this is needed to allow passing a lambda (with workspace_name) to map_each 
    )

    args.add_all(
        binary[PyInfo].imports, 
        format_each = "--sys-path=%s"
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
    args.add(py_toolchain.python, format = "--python=%s")

    py_version = py_toolchain.interpreter_version_info
    args.add_all(
        [
            constraint.format(major = py_version.major, minor = py_version.minor, patch = py_version.micro) 
            for constraint in ctx.attr.python_interpreter_constraints
        ], 
        format_each = "--python-version-constraint=%s"
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
        # See: https://github.com/bazelbuild/bazel/blob/b4ab259fe1cba8a108f1dd30067ee357c7198509/src/main/starlark/builtins_bzl/common/python/py_executable_bazel.bzl#L265
        OutputGroupInfo(
            python_zip_file = depset([output])
        )
    ]


_attrs = dict({
    "binary": attr.label(executable = True, cfg = "target"),
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

For example, to enforce same interpreter version that Bazel uses, following can be used.

```starlark
py_pex_binary
    python_interpreter_constraints = [
      "CPython=={major}.{minor}.{patch}"
    ]
)
```
"""),
    "_pex": attr.label(executable = True, cfg = "exec", default = "//py/tools/pex")
})


py_pex_binary = rule(
    doc = "Build a pex executable from a py_binary",
    implementation = _py_python_pex_impl,
    attrs = _attrs,
    toolchains = [
        PY_TOOLCHAIN
    ],
    executable = True,
)