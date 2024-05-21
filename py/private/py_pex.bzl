"Create python zip file https://peps.python.org/pep-0441/ (PEX)"

def _runfiles_path(file, workspace):
    if file.short_path.startswith("../"):
        return file.short_path[3:]
    else:
        return workspace + "/" + file.short_path

def _map_srcs(f, workspace):
    site_packages_i = f.path.find("site-packages")
    # determine if the src if a third party.
    if site_packages_i != -1 and f.path.count("/",  site_packages_i) == 2:
        if f.path.find("dist-info", site_packages_i) != -1:
            return ["--distinfo", f.dirname]
        return ["--dep", f.dirname]

    elif site_packages_i == -1:
        return ["--source=%s=%s" % (f.short_path, _runfiles_path(f, workspace))]

    return []

def build_pex(ctx, runfiles, srcs):
    output = ctx.actions.declare_file(ctx.attr.name + ".pex")
    args = ctx.actions.args()

    # copy workspace name here just in case to prevent ctx
    # to be transferred to execution phase.
    workspace_name = str(ctx.workspace_name)

    args.add_all(
        srcs, 
        map_each = lambda f: _map_srcs(f, workspace_name),
        uniquify = True,
        allow_closure = True,
    )
    args.add(ctx.file.main, format = "--executable=%s")
    args.add("#!/usr/bin/env python3", format="--python-shebang=%s")
    # args.add("python{}".format(
    #             py_toolchain.interpreter_version_info.major,
    #         ), format = "--python=%s")
    args.add(output, format = "--output-file=%s")

    ctx.actions.run(
        executable = ctx.executable._pex,
        inputs = runfiles.files,
        arguments = [args],
        outputs = [output]
    )    

    return output
  