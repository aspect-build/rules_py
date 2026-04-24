"""Unpacks a Python wheel into a directory and returns a PyInfo provider that represents that wheel"""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@rules_python//python:defs.bzl", "PyInfo")
load("//py/private:providers.bzl", "PyWheelsInfo")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "UNPACK_TOOLCHAIN")

def _py_unpacked_wheel_impl(ctx):
    py_toolchain = _py_semantics.resolve_toolchain(ctx)
    unpack_toolchain = ctx.toolchains[UNPACK_TOOLCHAIN]

    unpack_directory = ctx.actions.declare_directory("{}".format(ctx.attr.name))

    args = ctx.actions.args()
    args.add_all([unpack_directory], expand_directories = False, before_each = "--into")
    args.add("--wheel", ctx.file.src)
    args.add("--python-version-major", py_toolchain.interpreter_version_info.major)
    args.add("--python-version-minor", py_toolchain.interpreter_version_info.minor)

    ctx.actions.run(
        outputs = [unpack_directory],
        inputs = depset([ctx.file.src], transitive = [py_toolchain.files]),
        executable = unpack_toolchain.bin.bin,
        arguments = [args],
        execution_requirements = {"supports-path-mapping": "1"},
        mnemonic = "PyUnpackedWheel",
        progress_message = "Unpacking wheel {}".format(ctx.file.src.basename),
        toolchain = UNPACK_TOOLCHAIN,
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
    imports = _py_library.make_imports_depset(ctx, imports = [import_path])

    # site_packages_rfpath: runfiles-root-relative path to this wheel's
    # site-packages/, used by downstream rules to compute symlink targets
    # for the top-level names declared in `top_levels`.
    if ctx.label.workspace_name:
        site_packages_rfpath = paths.join(
            ctx.label.workspace_name,
            ctx.label.package,
            unpack_directory.basename,
            "lib",
            py_ver_dir,
            "site-packages",
        )
    else:
        site_packages_rfpath = paths.join(
            ctx.workspace_name,
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

    if ctx.attr.top_levels or ctx.attr.console_scripts:
        providers.append(PyWheelsInfo(
            wheels = depset(direct = [struct(
                top_levels = tuple(ctx.attr.top_levels),
                namespace_top_levels = tuple(ctx.attr.namespace_top_levels),
                site_packages_rfpath = site_packages_rfpath,
                console_scripts = tuple(ctx.attr.console_scripts),
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
        doc = """Names of the top-level packages / modules / *.dist-info directories the wheel installs into its site-packages.

When set, the target emits a `PyWheelsInfo` provider describing this wheel.
Downstream rules (such as `py_binary`) can consume this to assemble a merged
`site-packages/` tree via `ctx.actions.symlink` instead of relying on `.pth`
entries. If left empty (the default), the target behaves as before — other
rules fall back to `.pth`-based import resolution.

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
    "namespace_top_levels": attr.string_list(
        doc = """Subset of `top_levels` that are PEP 420 namespace packages.

See the equivalent attribute on the `whl_install` rule for the full
story; short version: names listed here suppress collision errors when
multiple wheels claim the same top-level, because Python's namespace
machinery is meant to merge their contributions.
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
        UNPACK_TOOLCHAIN,
    ],
)
