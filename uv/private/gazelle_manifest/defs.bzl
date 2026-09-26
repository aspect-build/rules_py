load("@bazel_lib//lib:transitions.bzl", "platform_transition_filegroup")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

def _wheel_path(file):
    if file.path.endswith(".whl") or file.path.endswith("/whl"):
        return file.path
    return None

def _modules_mapping_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".yaml")
    whls = depset(transitive = [target[DefaultInfo].files for target in ctx.attr.wheels])

    args = ctx.actions.args()
    args.add("--hub_name", ctx.attr.hub)
    args.add("--output", out)
    if ctx.attr.include_stub_packages:
        args.add("--include_stub_packages")

    whl_paths = ctx.actions.args()
    whl_paths.use_param_file("--whl_paths_file=%s", use_always = True)
    whl_paths.set_param_file_format("multiline")
    whl_paths.add_all(whls, map_each = _wheel_path, expand_directories = False)

    ctx.actions.run(
        executable = ctx.executable._generator,
        toolchain = None,
        arguments = [args, whl_paths],
        inputs = whls,
        outputs = [out],
        mnemonic = "PyGazelleModulesMapping",
        progress_message = "Generating Gazelle modules mapping %{label}",
    )

    return [DefaultInfo(files = depset([out]))]

_modules_mapping = rule(
    implementation = _modules_mapping_impl,
    attrs = {
        "wheels": attr.label_list(providers = [[DefaultInfo]]),
        "hub": attr.string(),
        "include_stub_packages": attr.bool(),
        "_generator": attr.label(
            default = Label("//uv/private/gazelle_manifest/tools:generator"),
            executable = True,
            cfg = "exec",
        ),
    },
)

update = Label("//uv/private/gazelle_manifest/tools:update.sh")

def gazelle_python_manifest(
        name,
        hub,
        venvs = [],
        include_stub_packages = False,
        platform_parent = None):
    """Generates a Gazelle Python manifest from uv-managed wheels.

    Args:
        name: Name of the generated manifest target.
        hub: Name of the uv hub containing the wheels.
        venvs: Dependency groups whose wheels should be indexed.
        include_stub_packages: Whether conventional stub distributions should be
            indexed for Gazelle's automatic stub dependency resolution.
        platform_parent: Parent platform for the synthetic platforms this macro
            uses to select each venv's wheels. Defaults to
            `Label("@platforms//host")`, resolved in rules_py's own repository —
            you do not need a `bazel_dep` on `platforms` to use the default. The
            host platform carries only OS and CPU constraints; point this at the
            platform the wheels should be resolved for when that is not enough:

            - If the build sets a custom `--host_platform` (for example to carry
              the constraints hermetic C++ toolchains require), pass that
              platform here so sdist builds inside the hub can still resolve a
              cc toolchain.
            - When cross-compiling, pass the target platform so wheel selection
              follows it instead of snapping back to the host. Note this makes
              `bazel run <name>.update` build any sdist fallbacks *for that
              platform*, which requires an execution platform able to run the
              build (e.g. remote execution) unless every indexed package
              resolves to a wheel.
    """
    if platform_parent == None:
        platform_parent = Label("@platforms//host")
    if type(platform_parent) not in ("string", "Label"):
        fail("gazelle_python_manifest: platform_parent takes a single platform label (Bazel's platform() rule accepts at most one parent); got {} of type {}".format(platform_parent, type(platform_parent)))

    file = "gazelle_python.yaml"
    hub = hub.lstrip("@")

    whls = []
    for venv in venvs:
        platform_name = "_{}_{}_{}".format(name, hub, venv)
        native.platform(
            name = platform_name,
            parents = [platform_parent],
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
