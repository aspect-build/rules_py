"Create python zip file https://peps.python.org/pep-0441/ (PEX)"

def _runfiles_path(file, workspace):
    if file.short_path.startswith("../"):
        return file.short_path[3:]
    else:
        return workspace + "/" + file.short_path

def _map_srcs(f, workspace):
    dest_path = _runfiles_path(f, workspace)

    # TODO: better way to exclude hermetic toolchain.
    if dest_path.find("toolchain") != -1:
        return []

    if dest_path.find("aspect_rules_py/py/tools/") != -1:
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

def build_pex(ctx, py_toolchain, runfiles, srcs):
    output = ctx.actions.declare_file(ctx.attr.name + ".pex")
    args = ctx.actions.args()

    # copy workspace name here just in case to prevent ctx
    # to be transferred to execution phase.
    workspace_name = str(ctx.workspace_name)

    args.add_all(
        ctx.attr.env.items(), 
        map_each = lambda e: "--inject-env=%s=%s" % (e[0], e[1]),
        allow_closure = True,
    )

    args.add_all(
        runfiles.files,
        map_each = lambda f: _map_srcs(f, workspace_name),
        uniquify = True,
        allow_closure = True,
    )
    args.add(ctx.file.main, format = "--executable=%s")
    args.add("#!/usr/bin/env python3", format = "--python-shebang=%s")
    args.add(py_toolchain.python, format = "--python=%s")
    args.add(output, format = "--output-file=%s")

    ctx.actions.run(
        executable = ctx.executable._pex,
        inputs = runfiles.files,
        arguments = [args],
        outputs = [output],
        # Unfortunately there is no way to disable pex cache, so just set it to . allow
        # bazel to discard cache once the action is done. 
        # TODO: this is probably not the right thing to do if the action is unsandboxed.
        env = {"PEX_ROOT": "."}
    )

    return output
