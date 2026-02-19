load("@bazel_lib//lib:transitions.bzl", "platform_transition_filegroup")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load("//uv/private/pprint:defs.bzl", "pprint")

def _modules_mapping_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".yaml")

    whl_file_deps = []
    for target in ctx.attr.wheels:
        files_depset = target[DefaultInfo].files
        whl_file_deps.append(files_depset)

    whl_depset = depset(
        transitive = whl_file_deps,
    )
    whl_files = [
        it
        for it in whl_depset.to_list()
        if it.path.endswith(".whl")
    ]

    args = ctx.actions.args()
    args.add_all(whl_files)
    args_file = ctx.actions.declare_file(ctx.label.name + ".args")
    ctx.actions.write(
        output = args_file,
        content = args,
        is_executable = False,
    )

    ctx.actions.run(
        executable = ctx.executable._generator,
        arguments = [
            "--whl_paths_file",
            args_file.path,
            # "--integrity_file", attr.file.integrity.path,
            "--output",
            out.path,
        ],
        inputs = [
            args_file,
        ] + whl_files,
        outputs = [
            out,
        ],
    )

    return [
        DefaultInfo(
            files = depset([
                out,
            ]),
        ),
    ]

_modules_mapping = rule(
    implementation = _modules_mapping_impl,
    attrs = {
        "wheels": attr.label_list(providers = [[DefaultInfo]]),
        # "integrity": attr.label(allow_single_file = True),
        "_generator": attr.label(
            default = Label(":generator"),
            executable = True,
            cfg = "exec",
        ),
    },
)

update = Label(":update.sh")

def gazelle_python_manifest(name, hub, venvs = [], lockfile = None):
    file = "gazelle_python.yaml"
    hub = hub.lstrip("@")

    whls = []
    for venv in venvs:
        platform_name = "_{}_{}_{}".format(name, hub, venv)
        native.platform(
            name = platform_name,
            parents = [
                "@platforms//host",
            ],
            flags = [
                "--@{}//venv={}".format(hub, venv),
            ],
        )
        platform_transition_filegroup(
            name = platform_name + "_whls",
            target_platform = platform_name,
            srcs = [
                "@{}//:gazelle_index_whls".format(hub),
            ],
        )
        whls.append(platform_name + "_whls")

    _modules_mapping(
        name = name,
        wheels = whls,
    )

    dest = native.package_name()
    if dest:
        dest = dest + "/"
    dest = dest + file

    sh_binary(
        name = name + ".update",
        srcs = [update],
        data = [name],
        args = ["$(location %s)" % name, dest],
    )
