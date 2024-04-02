"Create python zip file https://peps.python.org/pep-0441/"

def _normalize(path):
    if path.startswith("../"):
        return path[3:]
    if path.startswith("external/"):
        return path[9:]
    return path

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

def _map_file(file):
    return _mtree_line("runfiles/"+_normalize(file.path), "file", file.path)


def build_python_zip(ctx, output, runfiles, main):
    mtree = ctx.actions.declare_file(ctx.attr.name + ".spec")

    content = ctx.actions.args()
    content.use_param_file("@%s", use_always = True)
    content.set_param_file_format("multiline")
    content.add("#mtree")
    content.add(_mtree_line("__main__.py", "file", mode = "0555", content=main.path))
    content.add(_mtree_line("__init__.py", "file", mode = "0666"))

    for empty in runfiles.empty_filenames.to_list():
        content.add(_mtree_line(_normalize(empty.path), "file"))

    content.add_all(runfiles.files, map_each = _map_file)

    content.add("")
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
        inputs = depset(direct = [mtree], transitive = [bsdtar.default.files, runfiles.files]),
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

    return mtree


ZIP_TOOLCHAIN = "@aspect_bazel_lib//lib:tar_toolchain_type"