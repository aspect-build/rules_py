"""
"""

load("@rules_python//python:defs.bzl", "PyInfo")
load("@rules_python//python/private:toolchain_types.bzl", "EXEC_TOOLS_TOOLCHAIN_TYPE")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "UNPACK_TOOLCHAIN")

def _whl_install(ctx):
    py_toolchain = ctx.toolchains[PY_TOOLCHAIN].py3_runtime
    install_dir = ctx.actions.declare_directory(
        "install",
    )

    archive = ctx.file.src

    arguments = ctx.actions.args()

    # Pass File objects (not .path strings) so Bazel can rewrite paths for
    # remote-cache deduplication when supports-path-mapping is set.
    #
    # Both install_dir and archive may be tree artifacts (install_dir is always
    # a declare_directory; archive is a tree when src is a directory containing
    # a single wheel). Args#add rejects directories
    # outright; Args#add_all with expand_directories=False passes the directory
    # path itself without enumerating its contents.
    # https://bazel.build/versions/7.1.0/rules/lib/builtins/Args#add
    # https://bazel.build/versions/7.1.0/rules/lib/builtins/Args#add_all
    arguments.add_all([install_dir], expand_directories = False, before_each = "--into")
    arguments.add_all([archive], expand_directories = False, before_each = "--wheel")
    arguments.add("--python-version-major", py_toolchain.interpreter_version_info.major)
    arguments.add("--python-version-minor", py_toolchain.interpreter_version_info.minor)

    transitive_inputs = [depset([archive])]

    # Patch application (happens before pyc compilation).
    patch_files = [f for t in ctx.attr.patches for f in t[DefaultInfo].files.to_list()]
    if patch_files:
        arguments.add("--patch-strip", str(ctx.attr.patch_strip))
        arguments.add_all(patch_files, before_each = "--patch")
        transitive_inputs.append(depset(patch_files))

    # Optional .pyc pre-compilation (runs after patching).
    # Use the exec-configured interpreter from EXEC_TOOLS_TOOLCHAIN_TYPE so cross-arch
    # builds work (the target interpreter isn't runnable on the build host). This is
    # safe because .pyc bytecode varies by Python version, not by architecture.
    if ctx.attr.compile_pyc:
        exec_runtime = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN_TYPE].exec_tools.exec_runtime
        arguments.add("--compile-pyc")
        arguments.add("--pyc-invalidation-mode", ctx.attr.pyc_invalidation_mode)
        arguments.add("--python", exec_runtime.interpreter)
        transitive_inputs.append(depset([exec_runtime.interpreter], transitive = [exec_runtime.files]))

    # Need to read the toolchain config from the unpack target so we can grab
    # its bin and run it. Note that we have to do this dance in order to get the
    # unpack toolchain in the "exec" rather than target config. This allows us
    # to use unpack in crossbuild scenarios.
    unpack = ctx.attr._unpack[platform_common.ToolchainInfo].bin.bin
    ctx.actions.run(
        mnemonic = "WhlInstall",
        executable = unpack,
        arguments = [arguments],
        inputs = depset(transitive = transitive_inputs),
        outputs = [
            install_dir,
        ],
        use_default_shell_env = bool(patch_files),
        execution_requirements = {
            "supports-path-mapping": "1",
        },
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

We implement wheel installation without an interpreter (or even uv) by using our
unpack tool, which uses a subset of UV's machinery. Critically, this allows us
to bypass some of the platform checks that UV does to enable crossbuilds, and is
lighter weight since the toolchain's files aren't inputs.
""",
    attrs = {
        "src": attr.label(
            allow_single_file = True,
            doc = "The wheel to install, or a tree artifact containing exactly one wheel at its root.",
        ),
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
        "_unpack": attr.label(
            default = "//py/private/toolchain:resolved_unpack_toolchain",
            cfg = "exec",
        ),
    },
    toolchains = [
        PY_TOOLCHAIN,
        UNPACK_TOOLCHAIN,
        EXEC_TOOLS_TOOLCHAIN_TYPE,
    ],
    provides = [
        DefaultInfo,
        PyInfo,
    ],
)
