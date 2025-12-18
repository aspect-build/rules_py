"""
Actually building sdists.
"""

load("//py/private/py_venv:types.bzl", "VirtualenvInfo")

# buildifier: disable=bzl-visibility
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")
load("//uv/private:transitions.bzl", "transition_to_target")

TAR_TOOLCHAIN = "@tar.bzl//tar/toolchain:type"
# UV_TOOLCHAIN = "@multitool//tools/uv:toolchain_type"

def _sdist_build(ctx):
    py_toolchain = ctx.toolchains[PY_TOOLCHAIN].py3_runtime
    tar = ctx.toolchains[TAR_TOOLCHAIN]
    # uv = ctx.toolchains[UV_TOOLCHAIN]

    unpacked_sdist = ctx.actions.declare_directory(
        "src",
    )

    archive = ctx.attr.src[DefaultInfo].files.to_list()[0]

    # Extract the archive
    ctx.actions.run(
        executable = tar.tarinfo.binary,
        arguments = [
            "--strip-components=1",  # Ditch archive leader
            "-xf",
            archive.path,
            "-C",
            unpacked_sdist.path,
        ],
        inputs = [
            archive,
        ] + tar.default.files.to_list(),
        outputs = [
            unpacked_sdist,
        ],
    )

    # Now we need to do a build from the archive dir to a source artifact.
    wheel_dir = ctx.actions.declare_directory(
        "build",
    )

    venv = ctx.attr.venv
    # print(venv[VirtualenvInfo], venv[DefaultInfo])

    # Options here:
    # 1. `python3 -m build` which requires the build library and works generally
    # 2. `python3 setup.py bdist_wheel` which only requires setuptools but doesn't work for pyproject
    # 3. `uv build` which works generally but causes our venv shim to really struggle
    #
    # We're going with #1 for now.
    #
    # TODO: Figure out a way to provide defaults for build and its deps if the user doesn't.
    ctx.actions.run(
        executable = venv[VirtualenvInfo].home.path + "/bin/python3",
        arguments = [
            ctx.file._helper.path,
        ] + ctx.attr.args + [
            unpacked_sdist.path,
            wheel_dir.path,
        ],
        inputs = [
            unpacked_sdist,
            venv[VirtualenvInfo].home,
            ctx.file._helper,
        ] + py_toolchain.files.to_list() + ctx.attr.venv[DefaultInfo].files.to_list(),
        outputs = [
            wheel_dir,
        ],
    )

    return [
        DefaultInfo(
            files = depset([
                wheel_dir,
            ]),
        ),
    ]

sdist_build = rule(
    implementation = _sdist_build,
    doc = """Sdist to whl build rule.

Consumes a sdist artifact and performs a build of that artifact with the
specified Python dependencies under the configured Python toochain.

""",
    attrs = {
        "src": attr.label(),
        "venv": attr.label(),
        "args": attr.string_list(),
        "_helper": attr.label(allow_single_file = True, default = Label(":build_helper.py")),
    },
    toolchains = [
        # TODO: Py toolchain needs to be in the `host` configuration, not the
        # `exec` configuration. May need to split toolchains or use a different
        # one here. Ditto for the other tools.
        PY_TOOLCHAIN,
        TAR_TOOLCHAIN,
        # UV_TOOLCHAIN,
        # FIXME: Add in a cc toolchain here
    ],
)

sdist_native_build = rule(
    implementation = _sdist_build,
    doc = """Sdist to whl build rule _with native extensions_.

Consumes a sdist artifact and performs a build of that artifact with the
specified Python dependencies under the configured Python toochain.

Forces the exec platform to match the target platform so that we can safely
build packages with native code.

""",
    attrs = {
        "src": attr.label(doc = ""),
        "venv": attr.label(doc = ""),
        "args": attr.string_list(),
        "_helper": attr.label(allow_single_file = True, default = Label(":build_helper.py")),
    },
    cfg = transition_to_target,
    toolchains = [
        # TODO: Py toolchain needs to be in the `host` configuration, not the
        # `exec` configuration. May need to split toolchains or use a different
        # one here. Ditto for the other tools.
        PY_TOOLCHAIN,
        TAR_TOOLCHAIN,
        # UV_TOOLCHAIN,
        # FIXME: Add in a cc toolchain here
    ],
)
