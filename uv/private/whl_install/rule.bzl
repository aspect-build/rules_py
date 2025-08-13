"""
Installing wheels as a Bazel build action, rather than a repo step.
"""

load("@rules_python//python:defs.bzl", "PyInfo")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "UNPACK_TOOLCHAIN")


def _whl_install(ctx):
    py_toolchain = ctx.toolchains[PY_TOOLCHAIN].py3_runtime
    unpack_toolchain = ctx.toolchains[UNPACK_TOOLCHAIN]
    install_dir = ctx.actions.declare_directory(
        "install",
    )

    # Options here:
    # 1. Use `uv pip install` which doesn't have isolated
    # 2. Use the Python toolchain and a downloaded pip wheel to run install
    # 3. Just unzip the damn thing
    #
    # We're going with #1 for now.
    #
    # Could probably use bsdtar here rather than non-hermetic unzip.


    # FIXME: Need the Python toolchain here?
    archive = ctx.attr.src[DefaultInfo].files.to_list()[0]

    arguments = ctx.actions.args()
    arguments.add_all([
        "--into",
        install_dir.path,
        "--wheel",
        archive.path,
        "--python-version",
        "{}.{}.{}".format(
            py_toolchain.interpreter_version_info.major,
            py_toolchain.interpreter_version_info.minor,
            py_toolchain.interpreter_version_info.micro,
        ),
    ])

    ctx.actions.run(
        executable = unpack_toolchain.bin.bin,
        arguments = [arguments],
        inputs = [archive],
        outputs = [
            install_dir,
        ],
    )

    return [
        # FIXME: Need to generate PyInfo here
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

""",
    attrs = {
        "src": attr.label(doc = ""),
    },
    toolchains = [
        PY_TOOLCHAIN,
        UNPACK_TOOLCHAIN,
    ],
    provides = [
        DefaultInfo,
        PyInfo,
    ],
)
