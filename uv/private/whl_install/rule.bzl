"""
"""

load("@rules_python//python:defs.bzl", "PyInfo")
load("//py/private:providers.bzl", "PyWheelsInfo")
load("//py/private/toolchain:types.bzl", "EXEC_TOOLS_TOOLCHAIN", "PY_TOOLCHAIN")

SourceBuiltWheelInfo = provider(
    doc = "Analysis-time metadata declared for a source-built wheel.",
    fields = {
        "console_scripts": "Complete tuple[str] encoded as name=module:object.",
    },
)

def _source_built_wheel_impl(ctx):
    source = ctx.attr.src[DefaultInfo]
    return [
        # whl_install consumes this target as a single file. Reconstruct
        # DefaultInfo instead of forwarding the source target's executable,
        # which Bazel requires to be created by the rule that advertises it.
        DefaultInfo(files = source.files),
        SourceBuiltWheelInfo(
            console_scripts = tuple(ctx.attr.console_scripts),
        ),
    ]

source_built_wheel = rule(
    implementation = _source_built_wheel_impl,
    doc = "Mark a wheel target as source-built and attach declared metadata.",
    attrs = {
        "src": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "console_scripts": attr.string_list(),
    },
    provides = [SourceBuiltWheelInfo],
)

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
    unpack_script = ctx.file._unpack_script

    # Source-built wheels cannot be inspected during repository evaluation.
    # Check provenance before the basename: a custom source producer may reuse
    # a locked bdist filename, but its topology is still unknown.
    # Prebuilt wheel metadata is keyed by basename and selected for the active
    # configuration; metadata from inactive platform wheels must not leak in.
    if SourceBuiltWheelInfo in ctx.attr.src:
        top_levels = []
        top_level_dirs = []
        namespace_top_levels = []
        namespace_entries = []
        namespace_dirs = []
        regular_roots = []
        native_roots = []
        console_scripts = ctx.attr.src[SourceBuiltWheelInfo].console_scripts
    else:
        whl_basename = archive.basename
        top_levels = ctx.attr.top_levels.get(whl_basename, [])
        top_level_dirs = ctx.attr.top_level_dirs.get(whl_basename, [])
        namespace_top_levels = ctx.attr.namespace_top_levels.get(whl_basename, [])
        namespace_entries = ctx.attr.namespace_entries.get(whl_basename, [])
        namespace_dirs = ctx.attr.namespace_dirs.get(whl_basename, [])
        regular_roots = ctx.attr.regular_roots.get(whl_basename, [])
        native_roots = ctx.attr.native_roots.get(whl_basename, [])
        console_scripts = ctx.attr.console_scripts.get(whl_basename, [])

    arguments = ctx.actions.args()
    arguments.add(unpack_script)
    arguments.add_all([install_dir], expand_directories = False, before_each = "--into")
    arguments.add_all([archive], expand_directories = False, before_each = "--wheel")
    arguments.add("--python-version-major", py_toolchain.interpreter_version_info.major)
    arguments.add("--python-version-minor", py_toolchain.interpreter_version_info.minor)

    transitive_inputs = [
        depset([archive, unpack_script, exec_runtime.interpreter]),
        exec_runtime.files,
    ]

    # Patch application (happens before pyc compilation).
    patch_files = [f for t in ctx.attr.patches for f in t[DefaultInfo].files.to_list()]
    if patch_files:
        arguments.add("--patch-strip", str(ctx.attr.patch_strip))
        arguments.add_all(patch_files, before_each = "--patch")
        preserve_paths = {path: None for path in top_levels}
        for path in namespace_entries + namespace_dirs + regular_roots:
            root = path.split("/")[0]
            if not root.endswith(".dist-info") and not root.endswith(".egg-info"):
                preserve_paths[path] = None
        arguments.add_all(
            sorted(preserve_paths),
            before_each = "--preserve-path",
        )
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

    providers.append(PyWheelsInfo(
        wheels = depset(direct = [struct(
            top_levels = tuple(top_levels),
            # Directory-valued top-level entries from the RECORD skeleton.
            # Single-file modules are excluded so venv assembly only
            # physically merges directory claimants.
            top_level_dirs = tuple(top_level_dirs),
            # PEP 420 namespace packages this wheel contributes to.
            # When multiple wheels claim the same top-level and ALL of
            # them flag it as namespace, py_binary merges the namespace
            # CONCRETELY from `namespace_entries` per-entry symlinks
            # (so tools that inspect site-packages directly — mypy,
            # pyright — see the packages and their py.typed markers),
            # unless a regular package spans the wheels (detected via
            # `regular_roots` × `namespace_dirs`), which needs a
            # physical merge instead. Falls back to .pth-based
            # resolution when entry metadata is missing.
            namespace_top_levels = tuple(namespace_top_levels),
            # Concrete per-wheel paths beneath namespace top-levels
            # (e.g. `jaraco/functools`) that venv assembly symlinks
            # individually to materialise a merged namespace directory.
            namespace_entries = tuple(namespace_entries),
            # Directory skeleton under namespace top-levels: which dirs
            # are implicit-namespace portions (`namespace_dirs`) and
            # which are the minimal regular-package roots
            # (`regular_roots`). venv assembly cross-references these
            # across wheels to detect a regular package spanning wheels
            # (Python can't merge a regular package's __path__ at
            # runtime, so the subtree is physically merged).
            namespace_dirs = tuple(namespace_dirs),
            regular_roots = tuple(regular_roots),
            # Collision-relevant top-level directories, namespace dirs, and
            # regular roots containing native-library RECORD entries. Copying
            # one into a venv merge tree changes the library's physical origin.
            native_roots = tuple(native_roots),
            site_packages_rfpath = site_packages_rfpath,
            # Each entry is "name=module:func"; py_binary parses into
            # wrapper scripts at <venv>/bin/<name> at analysis time.
            console_scripts = tuple(console_scripts),
            # Tree artifact holding this wheel's installed file tree
            # (`install/`, whose internal shape is
            # `lib/python<M>.<m>/site-packages/...`). Consumed by
            # venv assembly's physical merge action (regular packages
            # spanning wheels) and by py_image_layer's pip-package
            # layer; the per-top-level venv symlinks reference each
            # wheel by its natural runfiles path rather than through
            # this File.
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

When the lookup hits, the selected wheel's `PyWheelsInfo` record carries this
layout and downstream rules can assemble a merged `site-packages/` tree via
`ctx.actions.symlink`. A miss leaves the layout unknown and preserves
`.pth`-based import behavior; the record still identifies the install tree for
consumers such as image layering.

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
        "top_level_dirs": attr.string_list_dict(
            doc = """Per-wheel subset of non-metadata top_levels that are directories, keyed by wheel file basename.

The wheel RECORD must contain an entry below the top-level directory.
Single-file modules are not included. venv assembly uses this distinction to
physically merge only colliding directories while preserving ordinary
file-collision precedence.
""",
            default = {},
        ),
        "namespace_top_levels": attr.string_list_dict(
            doc = """Per-wheel subset of `top_levels` that are PEP 420 namespace packages, keyed by wheel file basename.

A top-level is a namespace if the wheel's RECORD shows no
`<toplevel>/__init__.py`. When multiple wheels contribute to the same
namespace (e.g. `jaraco-classes` and `jaraco-functools` both claim
`jaraco`), `py_binary`'s collision detector treats the overlap as
benign and falls back to `.pth`-based resolution so Python's namespace
machinery merges the contributions at runtime.
""",
            default = {},
        ),
        "namespace_entries": attr.string_list_dict(
            doc = """Per-wheel concrete entries beneath the wheel's `namespace_top_levels`, keyed by wheel file basename.

Each entry is a `/`-joined site-packages-relative path to the shallowest
non-namespace member: a package directory holding a direct `__init__.py`
(`jaraco/functools`, `google/cloud/storage` — nested namespaces are
recursed through), or a plain module / data file (`jaraco/context.py`).
venv assembly symlinks each entry individually, materialising a merged
namespace directory in `site-packages/` so tools that inspect it directly
(mypy, pyright) see every contribution — and its `py.typed` markers —
without executing `.pth` files. Only the entry matching the selected wheel
(see `top_levels`) is used.
""",
            default = {},
        ),
        "namespace_dirs": attr.string_list_dict(
            doc = """Per-wheel implicit-namespace directory skeleton under the wheel's namespace top-levels, keyed by wheel file basename.

Every directory (as a `/`-joined path relative to site-packages) the wheel
installs files under without an `__init__.py` anywhere on the path. E.g.
azure-core-tracing-opentelemetry: `["azure/core", "azure/core/tracing",
"azure/core/tracing/ext"]`. venv assembly cross-references this with other
wheels' `regular_roots` to find regular packages that span wheels.
""",
            default = {},
        ),
        "regular_roots": attr.string_list_dict(
            doc = """Per-wheel minimal regular-package directories under the wheel's namespace top-levels, keyed by wheel file basename.

The shallowest directories (as `/`-joined paths relative to site-packages)
carrying an `__init__.py`. E.g. azure-core: `["azure/core"]`. When such a
root shows up in another wheel's `namespace_dirs`, that other wheel grafts
content inside this regular package — venv assembly must physically merge
the subtree since Python locks a regular package's `__path__` to one
directory.
""",
            default = {},
        ),
        "native_roots": attr.string_list_dict(
            doc = """Per-wheel collision roots containing native-library RECORD entries, keyed by wheel file basename.

Each value is a top-level directory, namespace directory, or regular-package
root containing a file ending in `.so`, versioned `.so.*`, `.pyd`, `.dylib`,
or `.dll`. venv assembly avoids physically merging a colliding root listed
here because relocation can break the library's origin-relative sibling lookup.
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
