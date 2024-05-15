"Create python zip file https://peps.python.org/pep-0441/"

def _mtree_line(file, type, content = None, uid = "0", gid = "0", time = "1672560000", mode = "0755"):
    spec = [
        file,
        "uid=" + uid,
        "gid=" + gid,
        "time=" + time,
        "mode=" + mode,
        "type=" + type,
    ]
    if content:
        spec.append("content=" + content)
    return " ".join(spec)


def _normalize(file, workspace):
    if file.short_path.startswith("../"):
        return file.short_path[3:]
    else:
        return workspace + "/" + file.short_path

def _map_file(file, workspace):
    return _mtree_line("runfiles/"+_normalize(file, workspace), "file", file.path)


def build_python_zip(ctx, output, runfiles, executable):
    content = ctx.actions.args()
    content.use_param_file("@%s", use_always = True)
    content.set_param_file_format("multiline")
    content.add("#mtree")
    content.add(_mtree_line("__main__.py", "file", mode = "0555", content=executable.path))
    content.add(_mtree_line("__init__.py", "file", mode = "0666"))



    # copy workspace name here just in case to prevent ctx
    # to be transferred to execution phase.
    workspace_name = str(ctx.workspace_name)

    content.add_all(
        runfiles.empty_filenames, 
        map_each = lambda f: _map_file(f, workspace_name),
        allow_closure = True
    )

    content.add_all(
        runfiles.files, 
        map_each = lambda f: _map_file(f, workspace_name),
        allow_closure = True
    )
    content.add("")

    mtree = ctx.actions.declare_file(ctx.attr.name + ".spec")
    ctx.actions.write(mtree, content = content)


    intermediate_zip = ctx.actions.declare_file(ctx.attr.name + ".intermediate.zip")
    bsdtar = ctx.toolchains[ZIP_TOOLCHAIN]
    args = ctx.actions.args()
    args.add("--create")
    args.add("--format", "zip")
    args.add("--file", intermediate_zip)
    args.add(mtree, format = "@%s")

    ctx.actions.run(
        executable = bsdtar.tarinfo.binary,
        inputs = depset(direct = [mtree, executable], transitive = [bsdtar.default.files, runfiles.files]),
        outputs = [intermediate_zip],
        arguments = [args],
        mnemonic = "PythonZipper",
        progress_message = "Building Python zip: %{label}",
    )

    ctx.actions.run_shell(
        command = "echo '{shebang}' | cat - {zip} > {output}".format(
            shebang = "#!/usr/bin/env python3",
            zip = intermediate_zip.path,
            output = output.path,
        ),
        inputs = [intermediate_zip],
        outputs = [output],
        use_default_shell_env = True,
        mnemonic = "BuildBinary",
        progress_message = "Build Python zip executable: %{label}",
    )

ZIP_TOOLCHAIN = "@aspect_bazel_lib//lib:tar_toolchain_type"