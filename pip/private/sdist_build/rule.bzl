load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "VENV_TOOLCHAIN")

def _sdist_build(ctx):
    py_toolchain = ctx.toolchains[PY_TOOLCHAIN].py3_runtime
    unpacked_sdist = ctx.actions.declare_directory(
        "src",
    )

    archive = ctx.attr.src[DefaultInfo].files.to_list()[0]

    # Extract the archive
    ctx.actions.run(
        executable = "tar",
        arguments = [
            "--strip-components=1", # Ditch archive leader
            "-xf",
            archive.path,
            "-C",
            unpacked_sdist.path,
        ],
        inputs = [
            archive,
        ],
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
        executable = "/opt/homebrew/bin/uv", # FIXME: Use UV from the ruleset
        arguments = [
            "build",
            "--wheel",
            "--offline",
            "--out-dir", wheel_dir.path,
            "--python", py_toolchain.interpreter.path,
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
    doc = """

""",
    attrs = {
        "src": attr.label(doc = ""),
        "deps": attr.label_list(doc = ""),
    },
    # FIXME: Using rules_python's toolchains...
    toolchains = [
        PY_TOOLCHAIN,
        # FIXME: Add in a cc toolchain here
    ]
)
