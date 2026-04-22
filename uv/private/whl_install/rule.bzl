load("//py/private:aspect_py_info.bzl", "AspectPyInfo")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "UNPACK_TOOLCHAIN")

def _whl_install(ctx):
    py_toolchain = ctx.toolchains[PY_TOOLCHAIN].py3_runtime
    install_dir = ctx.actions.declare_directory(
        "install",
    )

    imports_path = ctx.label.repo_name + "/install/lib/python{}.{}/site-packages".format(
        py_toolchain.interpreter_version_info.major,
        py_toolchain.interpreter_version_info.minor,
    )

    src_files = ctx.attr.src[DefaultInfo].files.to_list()
    if not src_files:
        site_packages_path = "lib/python{}.{}/site-packages".format(
            py_toolchain.interpreter_version_info.major,
            py_toolchain.interpreter_version_info.minor,
        )
        ctx.actions.run_shell(
            outputs = [install_dir],
            command = "mkdir -p %s/%s" % (install_dir.path, site_packages_path),
        )
        return [
            DefaultInfo(
                files = depset([install_dir]),
                runfiles = ctx.runfiles(files = [install_dir]),
            ),
            AspectPyInfo(
                transitive_sources = depset([install_dir]),
                imports = depset([imports_path]),
                has_py2_only_sources = False,
                has_py3_only_sources = True,
                uses_shared_libraries = False,
                type_stubs = depset(),
                transitive_type_stubs = depset(),
                runfiles = ctx.runfiles(files = [install_dir]),
                default_runfiles = ctx.runfiles(files = [install_dir]),
                transitive_uv_hashes = depset(),
            ),
        ]

    archive = src_files[0]

    arguments = ctx.actions.args()
    arguments.add_all([
        "--into",
        install_dir.path,
        "--wheel",
        archive.path,
        "--python-version-major",
        py_toolchain.interpreter_version_info.major,
        "--python-version-minor",
        py_toolchain.interpreter_version_info.minor,
    ])

    inputs = [archive]

    patch_files = [f for t in ctx.attr.patches for f in t[DefaultInfo].files.to_list()]
    if patch_files:
        arguments.add("--patch-strip", str(ctx.attr.patch_strip))
        for f in patch_files:
            arguments.add("--patch", f.path)
        inputs = inputs + patch_files

    if ctx.attr.compile_pyc:
        exec_py = ctx.attr._exec_python[platform_common.ToolchainInfo]
        arguments.add("--compile-pyc")
        arguments.add("--pyc-invalidation-mode", ctx.attr.pyc_invalidation_mode)
        arguments.add("--python")
        arguments.add(exec_py.interpreter.path)
        inputs = inputs + [exec_py.interpreter] + exec_py.files.to_list()

    unpack = ctx.attr._unpack[platform_common.ToolchainInfo].bin.bin
    ctx.actions.run(
        executable = unpack,
        arguments = [arguments],
        inputs = inputs,
        outputs = [
            install_dir,
        ],
        use_default_shell_env = bool(patch_files),
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
        AspectPyInfo(
            transitive_sources = depset([
                install_dir,
            ]),
            imports = depset([imports_path]),
            has_py2_only_sources = False,
            has_py3_only_sources = True,
            uses_shared_libraries = False,
            type_stubs = depset(),
            transitive_type_stubs = depset(),
            runfiles = ctx.runfiles(files = [install_dir]),
            default_runfiles = ctx.runfiles(files = [install_dir]),
            transitive_uv_hashes = depset(),
        ),
    ]

whl_install = rule(
    implementation = _whl_install,
    doc = """
Private implementation detail of aspect_rules_py//uv.

Installing wheels as a Bazel build action, rather than a repo step.

We implement wheel installation without an interpreter (or even uv) by using our
unpack tool, which uses a subset of UV's machinery. Critically, this allows us
to bypass some of the platform checks that UV does to enable crossbuilds, and is
lighter weight since the toolchain's files aren't inputs.
""",
    attrs = {
        "src": attr.label(doc = "The wheel to install, or a tree artifact containing exactly one wheel at its root."),
        "patches": attr.label_list(
            default = [],
            allow_files = [".patch", ".diff"],
            doc = "Patch files to apply after installation, in order.",
        ),
        "patch_strip": attr.int(
            default = 0,
            doc = "Strip count for patches (-p flag).",
        ),
        "compile_pyc": attr.bool(
            default = False,
            doc = "Pre-compile .pyc bytecode after unpacking and patching.",
        ),
        "pyc_invalidation_mode": attr.string(
            default = "checked-hash",
            values = ["checked-hash", "unchecked-hash", "timestamp"],
            doc = "PEP 552 invalidation mode for pre-compiled .pyc files.",
        ),
        "_exec_python": attr.label(
            default = "//py/private/toolchain:resolved_py_toolchain",
            cfg = "exec",
        ),
        "_unpack": attr.label(
            default = "//py/private/toolchain:resolved_unpack_toolchain",
            cfg = "exec",
        ),
    },
    toolchains = [
        PY_TOOLCHAIN,
        UNPACK_TOOLCHAIN,
    ],
    provides = [
        DefaultInfo,
        AspectPyInfo,
    ],
)
