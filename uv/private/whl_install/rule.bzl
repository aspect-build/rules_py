"""
"""

load("@rules_python//python:defs.bzl", "PyInfo")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "UNPACK_TOOLCHAIN")

def _whl_install(ctx):
    py_toolchain = ctx.toolchains[PY_TOOLCHAIN].py3_runtime
    install_dir = ctx.actions.declare_directory(
        "install",
    )

    archive = ctx.attr.src[DefaultInfo].files.to_list()[0]

    unpack = ctx.attr._unpack[platform_common.ToolchainInfo].bin.bin

    arguments = ctx.actions.args()
    arguments.add_all([
        unpack.path,
        py_toolchain.interpreter.path,
        "--into",
        install_dir.path,
        "--wheel",
        archive.path,
        "--python-version-major",
        py_toolchain.interpreter_version_info.major,
        "--python-version-minor",
        py_toolchain.interpreter_version_info.minor,
    ])

    ctx.actions.run(
        executable = ctx.file._install_script,
        arguments = [arguments],
        inputs = depset([archive], transitive = [py_toolchain.files]),
        tools = [unpack],
        outputs = [
            install_dir,
        ],
        mnemonic = "WhlInstall",
        progress_message = "Installing wheel %{label}",
        use_default_shell_env = True,
    )

    return [
        DefaultInfo(
            files = depset([
                install_dir,
            ]),
            runfiles = ctx.runfiles(files = [
                install_dir,
            ]),
        ),
        PyInfo(
            transitive_sources = depset([
                install_dir,
            ]),
            imports = depset([
                ctx.label.repo_name + "/install/lib/python{}.{}/site-packages".format(
                    py_toolchain.interpreter_version_info.major,
                    py_toolchain.interpreter_version_info.minor,
                ),
            ]),
            has_py2_only_sources = False,
            has_py3_only_sources = True,
            uses_shared_libraries = False,
        ),
    ]

whl_install = rule(
    implementation = _whl_install,
    doc = """
Private implementation detail of aspect_rules_py//uv.

Installing wheels as a Bazel build action, rather than a repo step.

We implement wheel installation without by using our unpack tool, which
uses a subset of UV's machinery. Critically, this allows us to bypass some
of the platform checks that UV does, to enable crossbuilds.
""",
    attrs = {
        "src": attr.label(doc = "The wheel to install, or a tree artifact containing exactly one wheel at its root."),
        "_unpack": attr.label(
            default = "//py/private/toolchain:resolved_unpack_toolchain",
            cfg = "exec",
        ),
        "_install_script": attr.label(
            default = "//uv/private/whl_install:install_wheel.sh",
            allow_single_file = True,
        ),
    },
    toolchains = [
        PY_TOOLCHAIN,
        UNPACK_TOOLCHAIN,
    ],
    provides = [
        DefaultInfo,
        PyInfo,
    ],
)
