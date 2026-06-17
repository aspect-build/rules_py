"""Unpacks a Python wheel into a directory and returns a PyInfo provider that represents that wheel"""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@rules_python//python:defs.bzl", "PyInfo")
load("//py/private:providers.bzl", "PyWheelsInfo")
load("//py/private:pth.bzl", "make_imports_depset")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private/toolchain:types.bzl", "EXEC_TOOLS_TOOLCHAIN", "PY_TOOLCHAIN")

def _py_unpacked_wheel_impl(ctx):
    py_toolchain = _py_semantics.resolve_toolchain(ctx)
    exec_runtime = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN].exec_tools.exec_runtime
    unpack_script = ctx.file._unpack_script

    invalid_directory_top_levels = [
        name
        for name in ctx.attr.directory_top_levels
        if name not in ctx.attr.top_levels
    ]
    if invalid_directory_top_levels:
        fail("{}: directory_top_levels entries are absent from top_levels: {}".format(
            ctx.label,
            invalid_directory_top_levels,
        ))

    unpack_directory = ctx.actions.declare_directory("{}".format(ctx.attr.name))

    args = ctx.actions.args()
    args.add(unpack_script)
    args.add_all([unpack_directory], expand_directories = False, before_each = "--into")
    args.add("--wheel", ctx.file.src)
    args.add("--python-version-major", py_toolchain.interpreter_version_info.major)
    args.add("--python-version-minor", py_toolchain.interpreter_version_info.minor)
    if ctx.attr.top_levels:
        directory_set = {name: True for name in ctx.attr.directory_top_levels}
        args.add("--expected-metadata", json.encode({
            "console_scripts": sorted(ctx.attr.console_scripts),
            "top_levels": {
                name: "directory" if name in directory_set else "file"
                for name in ctx.attr.top_levels
            },
        }))
    else:
        if ctx.attr.console_scripts:
            fail("{}: console_scripts requires complete top_levels metadata".format(ctx.label))
        args.add("--metadata-unavailable")

    ctx.actions.run(
        outputs = [unpack_directory],
        inputs = depset(
            [ctx.file.src, unpack_script, exec_runtime.interpreter],
            transitive = [py_toolchain.files, exec_runtime.files],
        ),
        executable = exec_runtime.interpreter,
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
        deps = getattr(ctx.attr, "deps", []),
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
            has_py2_only_sources = False,
            has_py3_only_sources = True,
            uses_shared_libraries = False,
        ),
    ]

    providers.append(PyWheelsInfo(
        wheels = depset(direct = [struct(
            top_levels = tuple(ctx.attr.top_levels),
            directory_top_levels = tuple(ctx.attr.directory_top_levels),
            namespace_top_levels = tuple(ctx.attr.namespace_top_levels),
            namespace_entries = tuple(ctx.attr.namespace_entries),
            namespace_dirs = tuple(ctx.attr.namespace_dirs),
            regular_roots = tuple(ctx.attr.regular_roots),
            topology_known = ctx.attr.topology_known,
            site_packages_rfpath = site_packages_rfpath,
            console_scripts = tuple(ctx.attr.console_scripts),
            # See whl_install rule for the rationale.
            install_tree = unpack_directory,
        )]),
    ))

    return providers

_attrs = {
    "_unpack_script": attr.label(
        default = "//py/tools/unpack:unpack.py",
        allow_single_file = True,
    ),
    "src": attr.label(
        doc = "The Wheel file, as defined by https://packaging.python.org/en/latest/specifications/binary-distribution-format/#binary-distribution-format",
        allow_single_file = [".whl"],
        mandatory = True,
    ),
    "top_levels": attr.string_list(
        doc = """Complete list of top-level packages / modules / *.dist-info directories the wheel installs into its site-packages.

Downstream rules (such as `py_binary`) use these names to assemble a merged
`site-packages/` tree via `ctx.actions.symlink`. If left empty (the default),
they preserve the complete wheel root so imports and `.pth` files remain
available.

Typically populated by the `uv` wheel-install repo rule. Hand-written
`py_unpacked_wheel` targets may populate this to use per-name symlinks.
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
    "directory_top_levels": attr.string_list(
        doc = "Complete subset of `top_levels` installed as directories.",
        default = [],
    ),
    "namespace_top_levels": attr.string_list(
        doc = "Subset of `top_levels` that are PEP 420 namespace packages.",
        default = [],
    ),
    "namespace_entries": attr.string_list(
        doc = "Concrete entries beneath `namespace_top_levels`.",
        default = [],
    ),
    "namespace_dirs": attr.string_list(
        doc = "Implicit-namespace directory skeleton beneath namespace top-levels.",
        default = [],
    ),
    "regular_roots": attr.string_list(
        doc = "Minimal regular-package roots beneath namespace top-levels.",
        default = [],
    ),
    "topology_known": attr.bool(
        doc = """Whether the topology attributes completely describe the wheel.

Set this for regular-only wheels as well as namespace wheels. When false,
directory collisions use the complete-wheel fallback because analysis cannot
distinguish an empty topology from omitted metadata.""",
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
