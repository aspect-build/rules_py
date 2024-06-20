"Create python zip file https://peps.python.org/pep-0441/ (PEX)"

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
    "rules_python~",
    "aspect_rules_py~/py/tools/"
]

def _map_srcs(f, workspace):
    dest_path = _runfiles_path(f, workspace)

    # TODO: better way to exclude hermetic toolchain.
    for exclude in exclude_paths:
        if dest_path.find(exclude) != -1:
            return []


    site_packages_i = f.path.find("site-packages")

    # determine if the src if a third party.
    if site_packages_i != -1 and f.path.count("/", site_packages_i) == 2:
        if f.path.find("dist-info", site_packages_i) != -1:
            return ["--distinfo", f.dirname]
        return ["--dep", f.dirname]

    elif site_packages_i == -1:
        return ["--source=%s=%s" % (f.path, dest_path)]

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
    )

    args.add_all(
        runfiles.files,
        map_each = lambda f: _map_srcs(f, workspace_name),
        uniquify = True,
        allow_closure = True,
    )
    args.add(binary[DefaultInfo].files_to_run.executable, format = "--executable=%s")
    args.add(ctx.attr.python_shebang, format = "--python-shebang=%s")
    args.add(py_toolchain.python, format = "--python=%s")
    args.add(output, format = "--output-file=%s")

    ctx.actions.run(
        executable = ctx.executable._pex,
        inputs = runfiles.files,
        arguments = [args],
        outputs = [output],
        mnemonic = "PyPex",
        progress_message = "Building PEX binary %{label}",
        # Unfortunately there is no way to disable pex cache, so just set it to . allow
        # bazel to discard cache once the action is done. 
        # TODO: this is probably not the right thing to do if the action is unsandboxed.
        env = {"PEX_ROOT": "."}
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