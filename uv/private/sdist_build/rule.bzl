"""
Actually building sdists.
"""

# buildifier: disable=bzl-visibility
load("//py/private/py_venv:types.bzl", "VirtualenvInfo")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "TARGET_EXEC_TOOLCHAIN")
load("//uv/private:defs.bzl", "lib_mode_transition")

def _sdist_build(ctx):
    py_toolchain = ctx.exec_groups["target"].toolchains[PY_TOOLCHAIN].py3_runtime
    # uv = ctx.toolchains[UV_TOOLCHAIN]

    archive = ctx.attr.src[DefaultInfo].files.to_list()[0]

    # Now we need to do a build from the archive dir to a source artifact.
    wheel_dir = ctx.actions.declare_directory(
        "whl",
    )

    venv = ctx.attr.venv
    # print(venv[VirtualenvInfo], venv[DefaultInfo])

    # Options here:
    # 1. `python3 -m build` which requires the build library and works generally
    # 2. `python3 setup.py bdist_wheel` which only requires setuptools but doesn't work for pyproject
    # 3. `uv build` which works generally but causes our venv shim to really struggle
    #
    # We're going with #1 for now.

    # Build patch arguments if pre_build_patches are specified
    patch_args = []
    patch_inputs = []
    if ctx.attr.pre_build_patches:
        patch_args.extend(["--patch-strip", str(ctx.attr.pre_build_patch_strip)])
        for target in ctx.attr.pre_build_patches:
            for f in target[DefaultInfo].files.to_list():
                patch_args.extend(["--patch", f.path])
                patch_inputs.append(f)

    # Note that we have to use exec_group = "target" to force this action to
    # inherit RBE placement properties matching the target platform so that
    # it'll run remotely.
    ctx.actions.run(
        mnemonic = "PySdistBuild",
        progress_message = "Source compiling {} to a whl".format(archive.basename),
        executable = venv[VirtualenvInfo].home.path + "/bin/python3",
        arguments = [
            ctx.file._helper.path,
        ] + ctx.attr.args + patch_args + [
            archive.path,
            wheel_dir.path,
        ],
        # FIXME: Shouldn't need to add the Python toolchain files explicitly here; should be transitives/defaultinfo of the venv.
        inputs = [
            archive,
            venv[VirtualenvInfo].home,
            ctx.file._helper,
        ] + py_toolchain.files.to_list() + ctx.attr.venv[DefaultInfo].files.to_list() + patch_inputs,
        outputs = [
            wheel_dir,
        ],
        env = {
            "SETUPTOOLS_SCM_PRETEND_VERSION": ctx.attr.version,
        } | ctx.configuration.default_shell_env,
        exec_group = "target",
    )

    return [
        DefaultInfo(
            files = depset([
                wheel_dir,
            ]),
        ),
    ]

_PATCH_ATTRS = {
    "pre_build_patches": attr.label_list(
        default = [],
        allow_files = [".patch", ".diff"],
        doc = "Patch files to apply to the extracted source before building.",
    ),
    "pre_build_patch_strip": attr.int(
        default = 0,
        doc = "Strip count for pre-build patches (-p flag to patch).",
    ),
}

sdist_build = rule(
    implementation = _sdist_build,
    doc = """Sdist to _anyarch_ whl build rule.

Consumes a sdist artifact and performs a build of that artifact with the
specified Python dependencies under the configured Python toochain.

""",
    attrs = {
        "src": attr.label(),
        "venv": attr.label(),
        "version": attr.string(),
        "args": attr.string_list(default = ["--validate-anyarch"]),
        "_helper": attr.label(allow_single_file = True, default = Label(":build_helper.py")),
    } | _PATCH_ATTRS,
    exec_groups = {
        # Copy-paste from above, but without the target constraint toolchain
        "target": exec_group(
            toolchains = [
                PY_TOOLCHAIN,
            ],
        ),
    },
    cfg = lib_mode_transition,
)

sdist_native_build = rule(
    implementation = _sdist_build,
    doc = """Sdist to whl build rule.

Consumes a sdist artifact and performs a build of that artifact with the
specified Python dependencies under the configured Python toochain to produce a
platform-specific bdist we can subsequently install or deploy.

The build is guaranteed to occur on an execution platform matching the
constraints of the target platform.

""",
    attrs = {
        "src": attr.label(),
        "venv": attr.label(),
        "version": attr.string(),
        "args": attr.string_list(),
        "_helper": attr.label(allow_single_file = True, default = Label(":build_helper.py")),
    } | _PATCH_ATTRS,
    exec_groups = {
        # Create an exec group which depends on a toolchain which can only be
        # resolved to exec_compatible_with constraints equal to the target. This
        # allows us to discover what those constraints need to be.
        "target": exec_group(
            toolchains = [
                PY_TOOLCHAIN,
                TARGET_EXEC_TOOLCHAIN,
            ],
        ),
    },
    cfg = lib_mode_transition,
)
