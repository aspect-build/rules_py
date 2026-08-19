load("@bazel_lib//lib:transitions.bzl", "platform_transition_filegroup")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

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
        if it.path.endswith(".whl") or it.path.endswith("/whl")
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
        toolchain = None,
        arguments = [
            "--hub_name",
            ctx.attr.hub,
            "--whl_paths_file",
            args_file.path,
            "--output",
            out.path,
        ] + (["--include_stub_packages"] if ctx.attr.include_stub_packages else []),
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
        "hub": attr.string(),
        "include_stub_packages": attr.bool(),
        "_generator": attr.label(
            default = Label(":generator"),
            executable = True,
            cfg = "exec",
        ),
    },
)

update = Label(":update.sh")

def gazelle_python_manifest(
        name,
        hub,
        venvs = [],
        include_stub_packages = False,
        platform_parents = None):
    """Generates a Gazelle Python manifest from uv-managed wheels.

    Args:
        name: Name of the generated manifest target.
        hub: Name of the uv hub containing the wheels.
        venvs: Dependency groups whose wheels should be indexed.
        include_stub_packages: Whether conventional stub distributions should be
            indexed for Gazelle's automatic stub dependency resolution.
        platform_parents: Single-element list holding the parent platform for the
            synthetic platforms this macro uses to select each venv's wheels.
            (Bazel's `platform()` rule accepts at most one parent; the list shape
            mirrors its `parents` attribute.) Defaults to
            `[Label("@platforms//host")]`, resolved in rules_py's own repository —
            you do not need a `bazel_dep` on `platforms` to use the default. The
            host platform carries only OS and CPU constraints; point this at the
            platform the wheels should be resolved for when that is not enough:

            - If the build sets a custom `--host_platform` (for example to carry
              the constraints hermetic C++ toolchains require), pass that
              platform here so sdist builds inside the hub can still resolve a
              cc toolchain.
            - When cross-compiling, pass the target platform so wheel selection
              follows it instead of snapping back to the host.
    """
    if platform_parents == None:
        platform_parents = [Label("@platforms//host")]
    if len(platform_parents) != 1:
        fail("gazelle_python_manifest: platform_parents must contain exactly one platform label (Bazel's platform() rule accepts at most one parent); got {}".format(platform_parents))

    file = "gazelle_python.yaml"
    hub = hub.lstrip("@")

    whls = []
    for venv in venvs:
        platform_name = "_{}_{}_{}".format(name, hub, venv)
        native.platform(
            name = platform_name,
            parents = platform_parents,
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
        include_stub_packages = include_stub_packages,
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
