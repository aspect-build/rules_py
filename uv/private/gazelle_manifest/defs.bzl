load("@bazel_lib//lib:transitions.bzl", "platform_transition_filegroup")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

def _modules_mapping_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".yaml")

    args = ctx.actions.args()
    whl_files = []
    for target in ctx.attr.wheels:
        target_files = [
            it
            for it in target[DefaultInfo].files.to_list()
            if it.path.endswith(".whl") or it.path.endswith("/whl") or it.path.endswith("/gazelle_index.json")
        ]
        whl_files.extend(target_files)
        args.add_joined(target_files, join_with = "\t", expand_directories = False)
    args_file = ctx.actions.declare_file(ctx.label.name + ".args")
    ctx.actions.write(
        output = args_file,
        content = args,
        is_executable = False,
    )

    ctx.actions.run(
        executable = ctx.executable._generator,
        toolchain = None,
        arguments = [
            "--hub_name",
            ctx.attr.hub,
            "--whl_paths_file",
            args_file.path,
            "--output",
            out.path,
        ],
        inputs = depset([args_file] + whl_files),
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
        "hub": attr.string(),
        "_generator": attr.label(
            default = Label(":generator"),
            executable = True,
            cfg = "exec",
        ),
    },
)

update = Label(":update.sh")

def gazelle_python_manifest(name, hub, venvs = []):
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
                "--@{}//dep_group={}".format(hub, venv),
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
        hub = hub,
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
