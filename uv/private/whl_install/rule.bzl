"""
"""

load("@rules_python//python:defs.bzl", "PyInfo")
load("//py/private:providers.bzl", "PyWheelsInfo")
load("//py/private/toolchain:types.bzl", "EXEC_TOOLS_TOOLCHAIN", "PY_TOOLCHAIN")

def _whl_install(ctx):
    py_toolchain = ctx.toolchains[PY_TOOLCHAIN].py3_runtime
    exec_runtime = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN].exec_tools.exec_runtime

    # Name the install tree after the target rather than a fixed "install"
    # so several whl_install targets can coexist in one package without
    # declaring conflicting outputs.
    install_dir = ctx.actions.declare_directory(
        ctx.label.name + ".install",
    )

    archive = ctx.file.src
    whl_basename = archive.basename
    top_levels = list(ctx.attr.top_levels.get(whl_basename, []))
    directory_top_levels = list(ctx.attr.directory_top_levels.get(whl_basename, []))
    namespace_top_levels = ctx.attr.namespace_top_levels.get(whl_basename, [])
    namespace_entries = ctx.attr.namespace_entries.get(whl_basename, [])
    namespace_dirs = ctx.attr.namespace_dirs.get(whl_basename, [])
    regular_roots = ctx.attr.regular_roots.get(whl_basename, [])
    console_scripts = ctx.attr.console_scripts.get(whl_basename, [])
    metadata_known = whl_basename in ctx.attr.top_levels
    if (metadata_known and ctx.attr.compile_pyc and
        any([name.endswith(".py") for name in top_levels]) and
        "__pycache__" not in top_levels):
        top_levels.append("__pycache__")
        directory_top_levels.append("__pycache__")
        namespace_top_levels.append("__pycache__")
    unpack_script = ctx.file._unpack_script
    arguments = ctx.actions.args()
    arguments.add(unpack_script)
    arguments.add_all([install_dir], expand_directories = False, before_each = "--into")
    arguments.add_all([archive], expand_directories = False, before_each = "--wheel")
    arguments.add("--python-version-major", py_toolchain.interpreter_version_info.major)
    arguments.add("--python-version-minor", py_toolchain.interpreter_version_info.minor)
    if metadata_known:
        directory_set = {name: True for name in directory_top_levels}
        arguments.add("--expected-metadata", json.encode({
            "console_scripts": sorted(console_scripts),
            "top_levels": {
                name: "directory" if name in directory_set else "file"
                for name in top_levels
            },
        }))
    else:
        arguments.add("--metadata-unavailable")

    transitive_inputs = [
        depset([archive, unpack_script, exec_runtime.interpreter]),
        exec_runtime.files,
    ]

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
        arguments.add("--compile-pyc")
        arguments.add("--pyc-invalidation-mode", ctx.attr.pyc_invalidation_mode)
        arguments.add("--python", exec_runtime.interpreter)

    ctx.actions.run(
        mnemonic = "WhlInstall",
        executable = exec_runtime.interpreter,
        toolchain = EXEC_TOOLS_TOOLCHAIN,
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

    # Runfiles-root-relative path to the install tree's site-packages.
    # Derived from the same label components as `install_dir` above so the
    # two can never drift apart.
    site_packages_rfpath = "/".join([
        segment
        for segment in [ctx.label.repo_name, ctx.label.package, ctx.label.name + ".install"]
        if segment
    ] + ["lib/python{}.{}/site-packages".format(
        py_toolchain.interpreter_version_info.major,
        py_toolchain.interpreter_version_info.minor,
    )])

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

    # Per-configuration metadata selection: `src` resolves (through the
    # repo rule's select_chain) to exactly one wheel for the active
    # configuration, and the metadata attrs are dicts keyed by wheel file
    # basename. Looking up the resolved wheel at analysis time limits the
    # advertised package surface (top-levels, console scripts) to the
    # wheel that is actually installed — metadata from inactive platform
    # wheels must not leak in (e.g. another platform's C-extension
    # suffix, or a console script shipped only by the win32 wheel).
    # A lookup miss (sbuild fallback, failed extraction at repo-fetch
    # time) leaves the package metadata empty, so consumers fall back to
    # .pth-based resolution. The wheel still emits PyWheelsInfo because
    # downstream venvs must own its install tree independently of whether
    # repository-time metadata extraction succeeded.
    #
    # A source-built wheel's topology does not exist until this action runs.
    # Its fallback root preserves ordinary imports, but analysis cannot merge
    # an unknown contribution into a regular package owned by another wheel.
    providers.append(PyWheelsInfo(
        wheels = depset(direct = [struct(
            top_levels = tuple(top_levels),
            directory_top_levels = tuple(directory_top_levels),
            namespace_top_levels = tuple(namespace_top_levels),
            namespace_entries = tuple(namespace_entries),
            namespace_dirs = tuple(namespace_dirs),
            regular_roots = tuple(regular_roots),
            site_packages_rfpath = site_packages_rfpath,
            # Each entry is "name=module:func"; py_binary parses into
            # wrapper scripts at <venv>/bin/<name> at analysis time.
            console_scripts = tuple(console_scripts),
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
        "_unpack_script": attr.label(
            default = "//py/tools/unpack:unpack.py",
            allow_single_file = True,
        ),
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
        "top_levels": attr.string_list_dict(
            doc = """Per-wheel top-level names, keyed by wheel file basename.

Each value lists the top-level packages / modules / *.dist-info directories
that wheel installs into its site-packages. At analysis time the entry whose
key matches the basename of the wheel `src` resolved to (the selected wheel
for the active configuration) is used; entries for other platform wheels are
ignored so their package surface cannot leak into this configuration.

The target emits a `PyWheelsInfo` provider for the selected wheel so downstream
venvs own its install tree. When the lookup hits, downstream rules (such as
`py_binary`) also assemble a merged `site-packages/` tree via
`ctx.actions.symlink` instead of relying on `.pth` entries. A miss preserves
the `.pth`-based import behavior.

Typically populated automatically by the `whl_install` repo rule from each
wheel's `*.dist-info/RECORD` at repo-fetch time.
""",
            default = {},
        ),
        "console_scripts": attr.string_list_dict(
            doc = """Per-wheel console-script entry points (`"name=module:func"`), keyed by wheel file basename.

Populated from each wheel's `*.dist-info/entry_points.txt`
`[console_scripts]` section by the `whl_install` repo rule at repo-fetch
time. Only the entry matching the selected wheel (see `top_levels`) is used.
`py_binary` consumes these via `PyWheelsInfo` to generate executable wrappers
under `<venv>/bin/<name>` so `subprocess.run(["<name>", ...])` works.
""",
            default = {},
        ),
        "directory_top_levels": attr.string_list_dict(
            doc = "Per-wheel subset of `top_levels` installed as directories.",
            default = {},
        ),
        "namespace_top_levels": attr.string_list_dict(
            doc = "Per-wheel subset of `top_levels` that are PEP 420 namespace packages.",
            default = {},
        ),
        "namespace_entries": attr.string_list_dict(
            doc = """Concrete entries beneath each wheel's namespace top-levels.

Venv assembly links these entries individually so static tools see one
concrete namespace directory without relocating wheel contents.
""",
            default = {},
        ),
        "namespace_dirs": attr.string_list_dict(
            doc = "Implicit-namespace directory skeleton beneath namespace top-levels.",
            default = {},
        ),
        "regular_roots": attr.string_list_dict(
            doc = """Minimal regular-package roots beneath namespace top-levels.

Cross-wheel comparison with `namespace_dirs` identifies a regular package
whose contents must be physically merged.
""",
            default = {},
        ),
    },
    toolchains = [
        PY_TOOLCHAIN,
        EXEC_TOOLS_TOOLCHAIN,
    ],
    provides = [
        DefaultInfo,
        OutputGroupInfo,
        PyInfo,
    ],
)
