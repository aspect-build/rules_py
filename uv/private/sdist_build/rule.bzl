"""
Actually building sdists.
"""

load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "TARGET_EXEC_TOOLCHAIN")
load("//uv/private:defs.bzl", "lib_mode_transition")

def _sdist_build(ctx):
    archive = ctx.attr.src[DefaultInfo].files.to_list()[0]

    wheel_dir = ctx.actions.declare_directory(
        "whl",
    )

    # Build patch arguments if pre_build_patches are specified
    patch_args = []
    patch_inputs = []
    if ctx.attr.pre_build_patches:
        patch_args.extend(["--patch-strip", str(ctx.attr.pre_build_patch_strip)])
        for target in ctx.attr.pre_build_patches:
            for f in target[DefaultInfo].files.to_list():
                patch_args.extend(["--patch", f.path])
                patch_inputs.append(f)

    # The build tool is a py_venv_binary wrapping build_helper.py. Using it as
    # a tool (not just an input) causes Bazel to materialize its runfiles in
    # the action sandbox, which means the venv shim can find the interpreter
    # via the standard runfiles mechanism regardless of whether the interpreter
    # comes from an external repo or the main workspace.
    ctx.actions.run(
        mnemonic = "PySdistBuild",
        progress_message = "Source compiling {} to a whl".format(archive.basename),
        executable = ctx.executable.tool,
        arguments = ctx.attr.args + patch_args + [
            archive.path,
            wheel_dir.path,
        ],
        inputs = [
            archive,
        ] + patch_inputs,
        tools = [ctx.attr.tool[DefaultInfo].files_to_run],
        outputs = [
            wheel_dir,
        ],
        env = {
            "SETUPTOOLS_SCM_PRETEND_VERSION": ctx.attr.version,
            # Determinism: fix hash seed so dict/set iteration order is stable
            "PYTHONHASHSEED": "0",
            # Determinism: reproducible timestamps in archives
            "SOURCE_DATE_EPOCH": "0",
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

_sdist_build_attrs = {
    "src": attr.label(),
    "tool": attr.label(executable = True, cfg = "target"),
    "version": attr.string(),
    "args": attr.string_list(default = ["--validate-anyarch"]),
} | _PATCH_ATTRS

sdist_build = rule(
    implementation = _sdist_build,
    doc = """Sdist to _anyarch_ whl build rule.

Consumes a sdist artifact and performs a build of that artifact with the
specified Python dependencies under the configured Python toochain.

""",
    attrs = _sdist_build_attrs,
    exec_groups = {
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
    attrs = _sdist_build_attrs | {
        "args": attr.string_list(),
    },
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
