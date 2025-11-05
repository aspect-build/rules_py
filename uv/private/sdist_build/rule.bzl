"""
Actually building sdists.
"""

# buildifier: disable=bzl-visibility
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")

TAR_TOOLCHAIN = "@tar.bzl//tar/toolchain:type"
UV_TOOLCHAIN = "@multitool//tools/uv:toolchain_type"

def _sdist_build(ctx):
    py_toolchain = ctx.toolchains[PY_TOOLCHAIN].py3_runtime
    tar = ctx.toolchains[TAR_TOOLCHAIN]
    uv = ctx.toolchains[UV_TOOLCHAIN]

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

    # Options here:
    # 1. Use `uv build` and provide it the path for our Python toolchain
    # 2. Use the Python toolchain and a downloaded build.
    #    This actually takes some doing since build requires packaging.
    #    Not too bad but not just one wheel.
    #
    # We're going with #1 for now.
    ctx.actions.run(
        executable = uv.executable,
        arguments = [
            "build",
            "--wheel",
            "--offline",
            "--no-cache",
            "--out-dir",
            wheel_dir.path,
            "--python",
            py_toolchain.interpreter.path,
            unpacked_sdist.path,
        ],
        inputs = [
            unpacked_sdist,
        ] + py_toolchain.files.to_list(),
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
        "src": attr.label(doc = ""),
        "deps": attr.label_list(doc = ""),
    },
    toolchains = [
        # TODO: Py toolchain needs to be in the `host` configuration, not the
        # `exec` configuration. May need to split toolchains or use a different
        # one here. Ditto for the other tools.
        PY_TOOLCHAIN,
        TAR_TOOLCHAIN,
        UV_TOOLCHAIN,
        # FIXME: Add in a cc toolchain here
    ],
)
