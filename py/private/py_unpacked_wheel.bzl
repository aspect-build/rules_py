"""Unpacks a Python wheel into a directory and returns a PyInfo provider that represents that wheel"""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("//py/private:providers.bzl", "PyWheelsInfo", "make_wheel_record")
load("//py/private:pth.bzl", "make_imports_depset")
load("//py/private:py_info.bzl", "PyInfo")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private/toolchain:types.bzl", "EXEC_TOOLS_TOOLCHAIN", "PY_TOOLCHAIN")

def _py_unpacked_wheel_impl(ctx):
    py_toolchain = _py_semantics.resolve_toolchain(ctx)
    unpack_tool = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN].unpack_tool

    unpack_directory = ctx.actions.declare_directory("{}".format(ctx.attr.name))

    args = ctx.actions.args()
    args.add_all(unpack_tool.arguments)
    args.add_all([unpack_directory], expand_directories = False, before_each = "--into")
    args.add("--wheel", ctx.file.src)
    args.add("--python-version", "{}.{}".format(
        py_toolchain.interpreter_version_info.major,
        py_toolchain.interpreter_version_info.minor,
    ))

    ctx.actions.run(
        outputs = [unpack_directory],
        inputs = depset(
            [ctx.file.src],
            transitive = [py_toolchain.files, unpack_tool.inputs],
        ),
        executable = unpack_tool.executable,
        arguments = [args],
        execution_requirements = {"supports-path-mapping": "1"},
        mnemonic = "PyUnpackedWheel",
        progress_message = "Unpacking wheel {}".format(ctx.file.src.basename),
        toolchain = EXEC_TOOLS_TOOLCHAIN,
    )

    py_ver_dir = "python{}.{}".format(
        py_toolchain.interpreter_version_info.major,
        py_toolchain.interpreter_version_info.minor,
    )
    import_path = paths.join(
        ".",
        unpack_directory.basename,
        "lib",
        py_ver_dir,
        "site-packages",
    )
    imports = make_imports_depset(
        deps = [],
        imports = [import_path],
        workspace_name = ctx.workspace_name,
        label = ctx.label,
    )

    # site_packages_rfpath: runfiles-root-relative path to this wheel's
    # site-packages/, used by downstream rules to compute symlink targets
    # for the top-level names declared in `top_levels`.
    site_packages_rfpath = paths.join(
        ctx.label.workspace_name if ctx.label.workspace_name else ctx.workspace_name,
        ctx.label.package,
        unpack_directory.basename,
        "lib",
        py_ver_dir,
        "site-packages",
    )

    providers = [
        DefaultInfo(
            files = depset(direct = [unpack_directory]),
            default_runfiles = ctx.runfiles(files = [unpack_directory]),
        ),
        PyInfo(
            imports = imports,
            transitive_sources = depset([unpack_directory]),
            virtual_dependencies = depset(),
            virtual_resolutions = depset(),
        ),
    ]

    providers.append(PyWheelsInfo(
        wheels = depset(direct = [make_wheel_record(
            top_levels = ctx.attr.top_levels,
            namespace_top_levels = ctx.attr.namespace_top_levels,
            namespace_entries = ctx.attr.namespace_entries,
            site_packages_rfpath = site_packages_rfpath,
            console_scripts = ctx.attr.console_scripts,
            data_files = ctx.attr.data_files,
            # See whl_install rule for the rationale.
            install_tree = unpack_directory,
        )]),
    ))

    return providers

_attrs = {
    "src": attr.label(
        doc = "The Wheel file, as defined by https://packaging.python.org/en/latest/specifications/binary-distribution-format/#binary-distribution-format",
        allow_single_file = [".whl"],
        mandatory = True,
    ),
    "top_levels": attr.string_list(
        doc = """Complete list of immediate entries the wheel installs into site-packages.

When set, downstream rules can assemble a merged `site-packages/` tree via
`ctx.actions.symlink` instead of relying on `.pth` entries. The list must
include packages, modules, `.pth` files, and `*.dist-info` directories. If left
empty (the default), other rules preserve the complete wheel root and fall back
to `.pth`-based import resolution.

Typically populated by the `uv` wheel-install repo rule. Hand-written
`py_unpacked_wheel` targets may populate this to opt into symlink-based
venv assembly.
""",
        default = [],
    ),
    "console_scripts": attr.string_list(
        doc = """Console-script entry points declared by this wheel, in the form `"name=module:func"`.

`py_binary` consumes these via `PyWheelsInfo` to generate executable
wrappers under `<venv>/bin/<name>`. Typically populated from the wheel's
`*.dist-info/entry_points.txt` `[console_scripts]` section.
""",
        default = [],
    ),
    "data_files": attr.string_list(
        doc = """PEP 427 `.data/data/` prefix-relative install paths (e.g. `share/foo/bar.txt`).

Venv assembly projects these into the venv prefix via `ctx.actions.symlink`.
Typically populated by the `uv` wheel-install repo rule; hand-written
`py_unpacked_wheel` targets may set it to expose data files shipped under
the wheel's `<name>-<version>.data/data/` tree.

Must list the wheel's prefix tree **completely**. Assembly binds a whole
directory with a single symlink when one wheel owns everything resolved
beneath it, so an undeclared file sitting next to a declared one is still
reachable under `sys.prefix` — an under-declared list changes which
collisions are reported, not what the venv exposes.
""",
        default = [],
    ),
    "namespace_top_levels": attr.string_list(
        doc = """Subset of `top_levels` that are PEP 420 namespace packages.

See the equivalent attribute on the `whl_install` rule for the full
story; short version: names listed here suppress collision errors when
multiple wheels claim the same top-level, because Python's namespace
machinery is meant to merge their contributions.
""",
        default = [],
    ),
    "namespace_entries": attr.string_list(
        doc = """Concrete entries this wheel installs beneath its `namespace_top_levels`.

See the equivalent attribute on the `whl_install` rule for the full
story; short version: `/`-joined paths like `jaraco/functools` that
let venv assembly materialise a merged namespace directory out of
per-entry symlinks, so static tools that inspect `site-packages/`
directly see the package. When empty, namespace merging falls back to
`.pth`-based resolution (runtime-only).
""",
        default = [],
    ),
}

py_unpacked_wheel = rule(
    implementation = _py_unpacked_wheel_impl,
    attrs = _attrs,
    provides = [PyInfo],
    toolchains = [
        PY_TOOLCHAIN,
        EXEC_TOOLS_TOOLCHAIN,
    ],
)
