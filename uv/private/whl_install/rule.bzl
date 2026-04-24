"""
"""

load("@rules_python//python:defs.bzl", "PyInfo")
load("//py/private:providers.bzl", "PyWheelsInfo")
load("//py/private/toolchain:types.bzl", "EXEC_TOOLS_TOOLCHAIN", "PY_TOOLCHAIN", "UNPACK_TOOLCHAIN")

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
    # Use the exec-configured interpreter from EXEC_TOOLS_TOOLCHAIN so cross-arch
    # builds work (the target interpreter isn't runnable on the build host). This is
    # safe because .pyc bytecode varies by Python version, not by architecture.
    if ctx.attr.compile_pyc:
        exec_runtime = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN].exec_tools.exec_runtime
        arguments.add("--compile-pyc")
        arguments.add("--pyc-invalidation-mode", ctx.attr.pyc_invalidation_mode)
        arguments.add("--python", exec_runtime.interpreter)
        transitive_inputs.append(depset([exec_runtime.interpreter], transitive = [exec_runtime.files]))

    unpack = ctx.toolchains[UNPACK_TOOLCHAIN].bin.bin
    ctx.actions.run(
        mnemonic = "WhlInstall",
        executable = unpack,
        toolchain = UNPACK_TOOLCHAIN,
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

    site_packages_rfpath = ctx.label.repo_name + "/install/lib/python{}.{}/site-packages".format(
        py_toolchain.interpreter_version_info.major,
        py_toolchain.interpreter_version_info.minor,
    )

    providers = [
        DefaultInfo(
            # install_dir is an intermediate artifact consumed by downstream
            # Python rules via PyInfo.transitive_sources. Excluding it from
            # DefaultInfo.files prevents it from appearing as a visible output
            # when building a binary that transitively depends on this wheel.
            runfiles = ctx.runfiles(files = [
                install_dir,
            ]),
        ),
        OutputGroupInfo(
            # Expose install_dir for consumers that need to access files from
            # the wheel directory directly (e.g. extracting non-console-script
            # binaries via a filegroup with output_group = "install_dir").
            install_dir = depset([install_dir]),
        ),
        PyInfo(
            transitive_sources = depset([
                install_dir,
            ]),
            imports = depset([site_packages_rfpath]),
            has_py2_only_sources = False,
            has_py3_only_sources = True,
            uses_shared_libraries = False,
        ),
    ]

    if ctx.attr.top_levels or ctx.attr.console_scripts:
        providers.append(PyWheelsInfo(
            wheels = depset(direct = [struct(
                top_levels = tuple(ctx.attr.top_levels),
                # PEP 420 namespace packages this wheel contributes to.
                # When multiple wheels claim the same top-level and ALL of
                # them flag it as namespace, py_binary treats the
                # collision as benign and falls back to .pth-based
                # resolution so Python's namespace-package machinery
                # merges contributions across wheels.
                namespace_top_levels = tuple(ctx.attr.namespace_top_levels),
                site_packages_rfpath = site_packages_rfpath,
                # Each entry is "name=module:func"; py_binary parses into
                # wrapper scripts at <venv>/bin/<name> at analysis time.
                console_scripts = tuple(ctx.attr.console_scripts),
                # Tree artifact holding this wheel's installed file tree
                # (`install/`, whose internal shape is
                # `lib/python<M>.<m>/site-packages/...`). Downstream
                # venv-assembly uses this as a `target_file` for a
                # per-wheel directory symlink, so the per-top-level
                # symlinks inside the venv can be intra-venv relative
                # (identical resolution in bazel-bin and runfiles).
                install_tree = install_dir,
            )]),
        ))

    return providers

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
        "top_levels": attr.string_list(
            doc = """Names of the top-level packages / modules / *.dist-info directories this wheel installs into its site-packages.

When set, the target emits a `PyWheelsInfo` provider describing this wheel.
Downstream rules (such as `py_binary`) can consume this to assemble a merged
`site-packages/` tree via `ctx.actions.symlink` instead of relying on `.pth`
entries. Empty default preserves existing `.pth`-based behavior.

Typically populated automatically by the `whl_install` repo rule from the
wheel's `*.dist-info/top_level.txt` or `RECORD` at repo-fetch time.
""",
            default = [],
        ),
        "console_scripts": attr.string_list(
            doc = """Console-script entry points declared by this wheel, in the form `"name=module:func"`.

Populated from the wheel's `*.dist-info/entry_points.txt` `[console_scripts]`
section by the `whl_install` repo rule at repo-fetch time. `py_binary`
consumes these via `PyWheelsInfo` to generate executable wrappers under
`<venv>/bin/<name>` so `subprocess.run(["<name>", ...])` works.
""",
            default = [],
        ),
        "namespace_top_levels": attr.string_list(
            doc = """Subset of `top_levels` that are PEP 420 namespace packages.

A top-level is a namespace if the wheel's RECORD shows no
`<toplevel>/__init__.py`. When multiple wheels contribute to the same
namespace (e.g. `jaraco-classes` and `jaraco-functools` both claim
`jaraco`), `py_binary`'s collision detector treats the overlap as
benign and falls back to `.pth`-based resolution so Python's namespace
machinery merges the contributions at runtime.
""",
            default = [],
        ),
    },
    toolchains = [
        PY_TOOLCHAIN,
        UNPACK_TOOLCHAIN,
        EXEC_TOOLS_TOOLCHAIN,
    ],
    provides = [
        DefaultInfo,
        OutputGroupInfo,
        PyInfo,
    ],
)
