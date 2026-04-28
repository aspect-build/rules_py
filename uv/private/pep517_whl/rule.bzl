"""
PEP 517 sdist-to-wheel build rules.

Uses `python -m build` (the pypa/build frontend) which delegates to whatever
build backend the sdist declares in its `[build-system]` table.
"""

load("@bazel_tools//tools/cpp:toolchain_utils.bzl", find_cc_toolchain = "find_cpp_toolchain")
load("//py/private/toolchain:types.bzl", "NATIVE_BUILD_TOOLCHAIN", "PY_TOOLCHAIN")

CC_TOOLCHAIN = "@bazel_tools//tools/cpp:toolchain_type"

def _common_env(ctx):
    return {
        "SETUPTOOLS_SCM_PRETEND_VERSION": ctx.attr.version,
        # Determinism: fix hash seed so dict/set iteration order is stable
        "PYTHONHASHSEED": "0",
        # Determinism: reproducible timestamps in archives
        "SOURCE_DATE_EPOCH": "0",
    } | ctx.configuration.default_shell_env

def _patch_args_and_inputs(ctx):
    patch_args = []
    patch_inputs = []
    if ctx.attr.pre_build_patches:
        patch_args.extend(["--patch-strip", str(ctx.attr.pre_build_patch_strip)])
        for target in ctx.attr.pre_build_patches:
            for f in target[DefaultInfo].files.to_list():
                patch_args.extend(["--patch", f.path])
                patch_inputs.append(f)
    return patch_args, patch_inputs

def _pep517_whl(ctx):
    archive = ctx.attr.src[DefaultInfo].files.to_list()[0]
    wheel_dir = ctx.actions.declare_directory("whl")
    patch_args, patch_inputs = _patch_args_and_inputs(ctx)

    # The build tool is a py_venv_binary wrapping build_helper.py. Using it as
    # a tool (not just an input) causes Bazel to materialize its runfiles in
    # the action sandbox, which means the venv shim can find the interpreter
    # via the standard runfiles mechanism regardless of whether the interpreter
    # comes from an external repo or the main workspace.
    ctx.actions.run(
        mnemonic = "PySdistBuild",
        progress_message = "Source compiling {} to a whl".format(archive.basename),
        executable = ctx.executable.tool,
        toolchain = None,
        arguments = ctx.attr.args + patch_args + [
            archive.path,
            wheel_dir.path,
        ],
        inputs = [archive] + patch_inputs,
        tools = [ctx.attr.tool[DefaultInfo].files_to_run],
        outputs = [wheel_dir],
        env = _common_env(ctx),
        exec_group = "target",
    )

    return [DefaultInfo(files = depset([wheel_dir]))]

def _pep517_native_whl(ctx):
    archive = ctx.attr.src[DefaultInfo].files.to_list()[0]
    wheel_dir = ctx.actions.declare_directory("whl")
    patch_args, patch_inputs = _patch_args_and_inputs(ctx)

    env = _common_env(ctx)
    extra_inputs = []

    # Resolve the CC toolchain so setuptools/distutils can find the compiler
    # rather than falling back to whatever is on the system PATH.
    cc_toolchain = find_cc_toolchain(ctx, mandatory = False)
    if cc_toolchain:
        env["CC"] = cc_toolchain.compiler_executable
        extra_inputs.append(cc_toolchain.all_files)

    ctx.actions.run(
        mnemonic = "PySdistNativeBuild",
        progress_message = "Native source compiling {} to a whl".format(archive.basename),
        executable = ctx.executable.tool,
        toolchain = None,
        arguments = ctx.attr.args + patch_args + [
            archive.path,
            wheel_dir.path,
        ],
        inputs = depset(
            [archive] + patch_inputs,
            transitive = extra_inputs,
        ),
        tools = [ctx.attr.tool[DefaultInfo].files_to_run],
        outputs = [wheel_dir],
        env = env,
        exec_group = "target",
    )

    return [DefaultInfo(files = depset([wheel_dir]))]

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

_pep517_whl_attrs = {
    "src": attr.label(),
    "tool": attr.label(executable = True, cfg = "exec"),
    "version": attr.string(),
    "args": attr.string_list(default = ["--validate-anyarch"]),
} | _PATCH_ATTRS

pep517_whl = rule(
    implementation = _pep517_whl,
    doc = """PEP 517 sdist to anyarch whl build rule.

Consumes a sdist artifact and performs a build of that artifact with the
specified Python dependencies under the configured Python toolchain.

""",
    attrs = _pep517_whl_attrs,
    exec_groups = {
        "target": exec_group(
            toolchains = [
                PY_TOOLCHAIN,
            ],
        ),
    },
)

pep517_native_whl = rule(
    implementation = _pep517_native_whl,
    doc = """PEP 517 sdist to platform-specific whl build rule.

Consumes a sdist artifact and performs a build of that artifact with the
specified Python dependencies under the configured Python toolchain to produce a
platform-specific bdist we can subsequently install or deploy.

The CC toolchain is resolved and `$CC` is set in the build environment so
that setuptools/distutils can find the hermetic compiler rather than falling
back to whatever is on the system PATH.

The build is guaranteed to occur on an execution platform matching the
constraints of the target platform.

""",
    attrs = _pep517_whl_attrs | {
        "args": attr.string_list(),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
    },
    exec_groups = {
        # Create an exec group which depends on a toolchain which can only be
        # resolved to exec_compatible_with constraints equal to the target. This
        # allows us to discover what those constraints need to be.
        #
        # NATIVE_BUILD_TOOLCHAIN has matching exec_compatible_with and
        # target_compatible_with, so this exec group only resolves when the exec
        # and target platforms match. Cross-compilation of sdists is intentionally
        # unsupported: PEP 517 build backends (setuptools, meson-python, etc.)
        # have no standard mechanism for cross-compilation, Python headers for
        # the target platform are not readily available, and output wheel tags
        # would need to encode the target platform with no upstream tooling
        # support. Packages that need cross-compiled native extensions should
        # publish pre-built wheels for their target platforms instead.
        "target": exec_group(
            toolchains = [
                PY_TOOLCHAIN,
                NATIVE_BUILD_TOOLCHAIN,
                CC_TOOLCHAIN,
            ],
        ),
    },
    toolchains = [
        config_common.toolchain_type(CC_TOOLCHAIN, mandatory = False),
    ],
    fragments = ["cpp"],
)
