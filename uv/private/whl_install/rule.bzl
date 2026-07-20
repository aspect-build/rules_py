"""
"""

load("//py/private:providers.bzl", "PyWheelsInfo", "make_wheel_record")
load("//py/private:py_info.bzl", "PyInfo")
load("//py/private/toolchain:types.bzl", "EXEC_TOOLS_TOOLCHAIN", "PY_TOOLCHAIN")

# SourceBuiltWheelInfo carries console scripts the pep517 builder detected in
# the built wheel; source_built_wheel consumes it below (unless overridden).
load("//uv/private:source_built_wheel.bzl", "SourceBuiltWheelInfo")

# exclude_glob: whl_dist extraction is exclude-agnostic, so when a package
# declares exclusions the selected wheel's retained RECORD paths are filtered
# and the layout is RE-DERIVED here at analysis time (matching pre-derivation
# semantics — an excluded initializer reclassifies namespace/regular).
load(":metadata.bzl", "derive_layout", "parse_exclude_glob", "record_path_excluded")

PyWheelMetadataInfo = provider(
    doc = """Analysis-time site-packages layout of a single wheel.

    Extracted from the wheel's `*.dist-info/RECORD` and `entry_points.txt` by
    the `whl_dist` repo rule (or declared, empty except `console_scripts`, for
    a source-built wheel of unknown layout). `whl_install` reads it off the
    wheel `select`ed for the active configuration, so only the selected wheel's
    surface reaches `PyWheelsInfo` — a sibling platform wheel's surface can
    never leak in because its metadata lives in its own repo and is never
    consulted here.

    Field semantics mirror the like-named `PyWheelsInfo` / `make_wheel_record`
    fields; all are `tuple[str]`.
    """,
    fields = {
        "top_levels": "All immediate site-packages entry names the wheel installs. Empty means unknown layout.",
        "top_level_dirs": "Subset of non-metadata top_levels that are directories.",
        "namespace_top_levels": "Subset of top_levels that are PEP 420 namespace packages.",
        "namespace_entries": "Concrete `/`-joined entries beneath the namespace top-levels.",
        "namespace_dirs": "Implicit-namespace directory skeleton under the namespace top-levels.",
        "regular_roots": "Minimal `__init__.py`-carrying directories under the namespace top-levels.",
        "native_roots": "Collision roots containing native-library RECORD entries.",
        "console_scripts": "`[console_scripts]` entry points encoded as name=module:object.",
        "record_paths": "Retained site-packages RECORD paths, for re-deriving the layout after exclude_glob. Empty unless a consuming package declares exclusions.",
    },
)

def _whl_dist_impl(ctx):
    return [
        DefaultInfo(files = depset([ctx.file.src])),
        PyWheelMetadataInfo(
            top_levels = tuple(ctx.attr.top_levels),
            top_level_dirs = tuple(ctx.attr.top_level_dirs),
            namespace_top_levels = tuple(ctx.attr.namespace_top_levels),
            namespace_entries = tuple(ctx.attr.namespace_entries),
            namespace_dirs = tuple(ctx.attr.namespace_dirs),
            regular_roots = tuple(ctx.attr.regular_roots),
            native_roots = tuple(ctx.attr.native_roots),
            console_scripts = tuple(ctx.attr.console_scripts),
            record_paths = tuple(ctx.attr.record_paths),
        ),
    ]

whl_dist = rule(
    implementation = _whl_dist_impl,
    doc = """A downloaded platform wheel plus its RECORD-derived site-packages layout.

Instantiated by the `whl_dist` repo rule in each per-wheel repo. Forwards the
`.whl` as its single default output and carries the extracted layout as
`PyWheelMetadataInfo`, so `whl_install` gets both the file and its metadata from
whichever wheel the `select` chain resolves to — without any sibling wheel repo
being fetched.
""",
    attrs = {
        "src": attr.label(
            allow_single_file = [".whl"],
            mandatory = True,
        ),
        "top_levels": attr.string_list(),
        "top_level_dirs": attr.string_list(),
        "namespace_top_levels": attr.string_list(),
        "namespace_entries": attr.string_list(),
        "namespace_dirs": attr.string_list(),
        "regular_roots": attr.string_list(),
        "native_roots": attr.string_list(),
        "console_scripts": attr.string_list(),
        "record_paths": attr.string_list(),
    },
    provides = [PyWheelMetadataInfo],
)

def _source_built_wheel_impl(ctx):
    source = ctx.attr.src[DefaultInfo]
    console_scripts = ctx.attr.console_scripts
    if not ctx.attr.console_scripts_override and SourceBuiltWheelInfo in ctx.attr.src:
        console_scripts = ctx.attr.src[SourceBuiltWheelInfo].console_scripts
    return [
        # whl_install consumes this target as a single file. Reconstruct
        # DefaultInfo instead of forwarding the source target's executable,
        # which Bazel requires to be created by the rule that advertises it.
        DefaultInfo(files = source.files),
        # Contents are unknowable until build time, so the layout is empty
        # (unknown → .pth-based resolution); only console scripts are known —
        # either declared (override) or detected by the pep517 builder and
        # forwarded here via SourceBuiltWheelInfo.
        PyWheelMetadataInfo(
            top_levels = (),
            top_level_dirs = (),
            namespace_top_levels = (),
            namespace_entries = (),
            namespace_dirs = (),
            regular_roots = (),
            native_roots = (),
            console_scripts = tuple(console_scripts),
            record_paths = (),
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
        "console_scripts_override": attr.bool(),
    },
    provides = [PyWheelMetadataInfo],
)

def pyc_compile_version_compatible(exec_info, target_info):
    """Whether .pyc built by `exec_info` is loadable by `target_info`.

    Requires the full version to match: CPython changes the bytecode magic
    number even between same-minor prereleases (e.g. 3.15.0a2 vs 3.15.0a6).
    """

    def tuple_of(info):
        return (info.major, info.minor, info.micro, info.releaselevel, info.serial)

    return tuple_of(exec_info) == tuple_of(target_info)

def _whl_install(ctx):
    py_toolchain = ctx.toolchains[PY_TOOLCHAIN].py3_runtime
    exec_runtime = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN].exec_runtime

    # Name the install tree after the target rather than a fixed "install"
    # so several whl_install targets can coexist in one package without
    # declaring conflicting outputs.
    install_dir = ctx.actions.declare_directory(
        ctx.label.name + ".install",
    )

    archive = ctx.file.src
    unpack_script = ctx.file._unpack_script

    # The layout of whichever wheel the `select` chain resolved to for the
    # active configuration — its own repo's RECORD-derived metadata (or empty,
    # for a source-built wheel). A sibling platform wheel's surface can't leak
    # in: it lives in a different repo that is never fetched or consulted here.
    meta = ctx.attr.src[PyWheelMetadataInfo]

    # exclude_glob removes files from the install tree (via --exclude-glob on
    # the action below). To keep the advertised layout consistent with that
    # tree, filter the selected wheel's retained RECORD paths and RE-DERIVE the
    # topology — matching the pre-derivation semantics: removing an initializer
    # reclassifies a package regular→namespace, and removing the last file under
    # a top-level drops it, so venv assembly never projects a dangling symlink
    # or mis-merges. console_scripts live under bin/, so exclusions never touch
    # them. record_paths is carried only for wheels of excluding packages; a
    # source-built wheel has none, and its layout is already empty.
    if ctx.attr.exclude_glob and meta.record_paths:
        patterns = [parse_exclude_glob(pattern) for pattern in ctx.attr.exclude_glob]
        retained = [
            path.split("/")
            for path in meta.record_paths
            if not record_path_excluded(path.split("/"), patterns)
        ]
        layout = derive_layout(retained)
        top_levels = layout.top_levels
        top_level_dirs = layout.top_level_dirs
        namespace_top_levels = layout.namespace_top_levels
        namespace_entries = layout.namespace_entries
        namespace_dirs = layout.namespace_dirs
        regular_roots = layout.regular_roots
        native_roots = layout.native_roots
    else:
        top_levels = meta.top_levels
        top_level_dirs = meta.top_level_dirs
        namespace_top_levels = meta.namespace_top_levels
        namespace_entries = meta.namespace_entries
        namespace_dirs = meta.namespace_dirs
        regular_roots = meta.regular_roots
        native_roots = meta.native_roots
    console_scripts = meta.console_scripts

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
    if ctx.attr.exclude_glob:
        arguments.add_all(ctx.attr.exclude_glob, format_each = "--exclude-glob=%s")
        transitive_inputs.append(depset([ctx.file._exclude_glob_script]))

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
    # Use the exec-configured interpreter from the exec-tools toolchain so cross-arch
    # builds work (the target interpreter isn't runnable on the build host). Skip it
    # when the exec runtime isn't the exact same interpreter version as the target:
    # CPython changes the bytecode magic number even between same-minor prereleases
    # (e.g. 3.15.0a2 vs 3.15.0a6), so a mismatched exec runtime writes .pyc unusable
    # by the target under lib/python{version}/.
    exec_matches_target = pyc_compile_version_compatible(
        exec_runtime.interpreter_version_info,
        py_toolchain.interpreter_version_info,
    )
    if ctx.attr.compile_pyc and exec_matches_target:
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
            virtual_dependencies = depset(),
            virtual_resolutions = depset(),
        ),
    ]

    providers.append(PyWheelsInfo(
        # See make_wheel_record / the PyWheelsInfo field docs for each
        # field's semantics. `install_tree` holds the installed file tree
        # (`install/`, internally `lib/python<M>.<m>/site-packages/...`);
        # venv assembly's per-top-level symlinks reference each wheel by
        # its natural runfiles path rather than through this File.
        wheels = depset(direct = [make_wheel_record(
            top_levels = top_levels,
            top_level_dirs = top_level_dirs,
            namespace_top_levels = namespace_top_levels,
            namespace_entries = namespace_entries,
            namespace_dirs = namespace_dirs,
            regular_roots = regular_roots,
            native_roots = native_roots,
            site_packages_rfpath = site_packages_rfpath,
            console_scripts = console_scripts,
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
        "_exclude_glob_script": attr.label(
            default = "//py/tools/unpack:exclude_glob.py",
            allow_single_file = True,
        ),
        "src": attr.label(
            allow_single_file = True,
            doc = "The wheel to install. Must provide PyWheelMetadataInfo (a `whl_dist` or `source_built_wheel` target); its metadata drives the installed layout.",
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
        "exclude_glob": attr.string_list(
            default = [],
            doc = "Site-packages-relative glob patterns to remove after installation.",
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
