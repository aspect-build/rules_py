"""Unpacks a Python wheel into a directory and returns a PyInfo provider that represents that wheel"""

load("@rules_python//python:defs.bzl", "PyInfo")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "UNPACK_TOOLCHAIN")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")

def _py_unpacked_wheel_impl(ctx):
    py_toolchain = _py_semantics.resolve_toolchain(ctx)
    unpack_toolchain = ctx.toolchains[UNPACK_TOOLCHAIN]

    unpack_directory = ctx.actions.declare_directory("{}".format(ctx.attr.name))

    arguments = ctx.actions.args()
    arguments.add_all([
        "--into",
        unpack_directory.path,
        "--wheel",
        ctx.file.src.path,
        "--python-version",
        "{}.{}.{}".format(
            py_toolchain.interpreter_version_info.major,
            py_toolchain.interpreter_version_info.minor,
            py_toolchain.interpreter_version_info.micro,
        ),
    ])

    ctx.actions.run(
        outputs = [unpack_directory],
        inputs = depset([ctx.file.src], transitive = [py_toolchain.files]),
        executable = unpack_toolchain.bin,
        arguments = [arguments],
        mnemonic = "PyUnpackedWheel",
        progress_message = "Unpacking wheel {}".format(ctx.file.src.basename),
        toolchain = UNPACK_TOOLCHAIN,
    )

    import_path = paths.join(
        ".",
        unpack_directory.basename,
        "lib",
        "python{}.{}".format(
            py_toolchain.interpreter_version_info.major,
            py_toolchain.interpreter_version_info.minor,
        ),
        "site-packages",
    )
    imports = _py_library.make_imports_depset(ctx, imports = [import_path])

    return [
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

_attrs = {
    "src": attr.label(
        doc = "The Wheel file, as defined by https://packaging.python.org/en/latest/specifications/binary-distribution-format/#binary-distribution-format",
        allow_single_file = [".whl"],
        mandatory = True,
    ),
    # NB: this is read by _resolve_toolchain in py_semantics.
    "_interpreter_version_flag": attr.label(
        default = "//py:interpreter_version",
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
