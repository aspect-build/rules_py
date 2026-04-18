"""PEP 517 sdist-to-wheel build rules.

Uses `python -m build` (the pypa/build frontend) which delegates to whatever
build backend the sdist declares in its `[build-system]` table.

Hermetic build process:
1. UNPACK_TOOLCHAIN extracts sdist -> source directory
2. Patches (if any) are applied to the extracted source
3. build_helper.py runs `python -m build` on the prepared source
"""

load("@bazel_tools//tools/cpp:toolchain_utils.bzl", find_cc_toolchain = "find_cpp_toolchain")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "TARGET_EXEC_TOOLCHAIN", "UNPACK_TOOLCHAIN")
load("//uv/private:defs.bzl", "lib_mode_transition")

CC_TOOLCHAIN = "@bazel_tools//tools/cpp:toolchain_type"

def _common_env(ctx):
    """Return a dictionary of environment variables for deterministic builds.

    The returned dictionary forces a fixed hash seed, reproducible timestamps,
    and a pretend version for setuptools-scm. It is merged with the default
    shell environment of the current Bazel configuration.
    """
    return {
        "SETUPTOOLS_SCM_PRETEND_VERSION": ctx.attr.version,
        "PYTHONHASHSEED": "0",
        "SOURCE_DATE_EPOCH": "0",
    } | ctx.configuration.default_shell_env

def _pep517_whl_impl(ctx, exec_group_name = "target", extra_inputs = [], env = None):
    """Shared implementation for PEP 517 wheel builds.

    Performs three sequential actions:
      1. Extract the provided archive (wheel or tarball) into a directory.
      2. Copy the extracted contents into a mutable source directory and apply
         any pre-build patches configured on the target.
      3. Invoke the configured build tool (usually build_helper.py) to produce
         a wheel directory from the prepared source.

    Args:
      ctx:             the rule context.
      exec_group_name: name of the exec_group used for the build action.
      extra_inputs:    additional input files to pass to the build action.
      env:             optional environment dictionary; if None, `_common_env`
                       is used.

    Returns:
      A list containing a single `DefaultInfo` provider whose `files` depset
      holds the declared wheel output directory.
    """
    archive = ctx.attr.src[DefaultInfo].files.to_list()[0]
    wheel_dir = ctx.actions.declare_directory("whl")
    extracted_dir = ctx.actions.declare_directory(ctx.attr.name + "_extracted")
    source_dir = ctx.actions.declare_directory(ctx.attr.name + "_src")
    py_toolchain = ctx.toolchains[PY_TOOLCHAIN].py3_runtime

    if archive.basename.endswith(".whl"):
        unpack_toolchain = ctx.toolchains[UNPACK_TOOLCHAIN]
        unpack_bin = unpack_toolchain.bin.bin
        extract_args = ctx.actions.args()
        extract_args.add_all([
            "--into",
            extracted_dir.path,
            "--wheel",
            archive.path,
            "--python-version-major",
            py_toolchain.interpreter_version_info.major,
            "--python-version-minor",
            py_toolchain.interpreter_version_info.minor,
        ])
        ctx.actions.run(
            mnemonic = "PySdistExtract",
            progress_message = "Extracting sdist {}".format(archive.basename),
            executable = unpack_bin,
            arguments = [extract_args],
            inputs = [archive],
            outputs = [extracted_dir],
            toolchain = UNPACK_TOOLCHAIN,
        )
    else:
        tar_flags = "-xf"
        if archive.basename.endswith(".gz") or archive.basename.endswith(".tgz"):
            tar_flags = "-xzf"
        elif archive.basename.endswith(".bz2"):
            tar_flags = "-xjf"
        elif archive.basename.endswith(".xz"):
            tar_flags = "-xJf"
        ctx.actions.run_shell(
            mnemonic = "PySdistExtract",
            progress_message = "Extracting sdist {}".format(archive.basename),
            outputs = [extracted_dir],
            inputs = [archive],
            command = "mkdir -p {out} && tar {flags} {archive} -C {out} --strip-components=1".format(
                out = extracted_dir.path,
                flags = tar_flags,
                archive = archive.path,
            ),
            use_default_shell_env = True,
        )

    patch_files = []
    if ctx.attr.pre_build_patches:
        for target in ctx.attr.pre_build_patches:
            patch_files.extend(target[DefaultInfo].files.to_list())

    patch_cmds = []
    if patch_files:
        patch_cmds.append("patch -p{strip} -d {out} < {patch}".format(
            strip = ctx.attr.pre_build_patch_strip,
            out = source_dir.path,
            patch = patch_files[0].path,
        ))
        for f in patch_files[1:]:
            patch_cmds.append("patch -p{strip} -d {out} < {patch}".format(
                strip = ctx.attr.pre_build_patch_strip,
                out = source_dir.path,
                patch = f.path,
            ))

    ctx.actions.run_shell(
        mnemonic = "PySdistPatch",
        progress_message = "Patching {}".format(archive.basename) if patch_files else "Preparing {}".format(archive.basename),
        inputs = [extracted_dir] + patch_files,
        outputs = [source_dir],
        command = "mkdir -p {out} && tar -cC {src} . | tar -xC {out} && chmod -R u+w {out}".format(
            src = extracted_dir.path,
            out = source_dir.path,
        ) + (" && " + " && ".join(patch_cmds) if patch_cmds else ""),
        use_default_shell_env = True,
    )

    ctx.actions.run(
        mnemonic = "PySdistBuild",
        progress_message = "Source compiling {} to a whl".format(archive.basename),
        executable = ctx.executable.tool,
        arguments = ctx.attr.args + [
            source_dir.path,
            wheel_dir.path,
        ],
        inputs = [source_dir] + extra_inputs,
        tools = [ctx.attr.tool[DefaultInfo].files_to_run],
        outputs = [wheel_dir],
        env = env if env != None else _common_env(ctx),
        exec_group = exec_group_name,
    )

    return [DefaultInfo(files = depset([wheel_dir]))]

def _pep517_whl(ctx):
    """Rule implementation for PEP 517 any-arch wheel builds."""
    return _pep517_whl_impl(ctx, exec_group_name = "target")

def _pep517_native_whl(ctx):
    """Rule implementation for PEP 517 platform-specific wheel builds.

    Resolves the C/C++ toolchain and injects the compiler path into `$CC` so
    that setuptools/distutils uses the hermetic compiler instead of whatever
    happens to be on the host PATH.
    """
    extra_inputs = []
    env = _common_env(ctx)
    cc_toolchain = find_cc_toolchain(ctx, mandatory = False)
    if cc_toolchain:
        env["CC"] = cc_toolchain.compiler_executable
        extra_inputs.extend(cc_toolchain.all_files.to_list())

    return _pep517_whl_impl(ctx, exec_group_name = "target", extra_inputs = extra_inputs, env = env)

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

Hermetic build process:
1. UNPACK_TOOLCHAIN extracts sdist -> source directory
2. UNPACK_TOOLCHAIN applies patches (if any) to source directory
3. build_helper.py runs `python -m build` on the prepared source
""",
    attrs = _pep517_whl_attrs,
    exec_groups = {
        "target": exec_group(
            toolchains = [
                PY_TOOLCHAIN,
                UNPACK_TOOLCHAIN,
            ],
        ),
    },
    toolchains = [
        PY_TOOLCHAIN,
        UNPACK_TOOLCHAIN,
    ],
    cfg = lib_mode_transition,
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

Hermetic build process:
1. UNPACK_TOOLCHAIN extracts sdist -> source directory
2. UNPACK_TOOLCHAIN applies patches (if any) to source directory
3. build_helper.py runs `python -m build` on the prepared source
""",
    attrs = _pep517_whl_attrs | {
        "args": attr.string_list(),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
    },
    exec_groups = {
        "target": exec_group(
            toolchains = [
                PY_TOOLCHAIN,
                TARGET_EXEC_TOOLCHAIN,
                CC_TOOLCHAIN,
                UNPACK_TOOLCHAIN,
            ],
        ),
    },
    toolchains = [
        PY_TOOLCHAIN,
        config_common.toolchain_type(CC_TOOLCHAIN, mandatory = False),
        UNPACK_TOOLCHAIN,
    ],
    fragments = ["cpp"],
    cfg = lib_mode_transition,
)
