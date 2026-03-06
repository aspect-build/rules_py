"""Rule that chains whl_install with patch application, preserving PyInfo.

This exists because a standalone apply_patches would only return DefaultInfo,
but downstream consumers need PyInfo with the correct imports path. This rule
applies patches to the installed tree artifact and re-wraps the result with
PyInfo.
"""

load("@rules_python//python:defs.bzl", "PyInfo")

# buildifier: disable=bzl-visibility
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "UNPACK_TOOLCHAIN")
load("//uv/private/diffutils:defs.bzl", "PATCH_TOOL_LABEL")

def _whl_apply_patches(ctx):
    py_toolchain = ctx.toolchains[PY_TOOLCHAIN].py3_runtime

    # Step 1: Run the normal whl_install (unpack)
    archive = ctx.attr.src[DefaultInfo].files.to_list()[0]

    unpatched_dir = ctx.actions.declare_directory("unpatched_install")

    arguments = ctx.actions.args()
    arguments.add_all([
        "--into",
        unpatched_dir.path,
        "--wheel",
        archive.path,
        "--python-version-major",
        py_toolchain.interpreter_version_info.major,
        "--python-version-minor",
        py_toolchain.interpreter_version_info.minor,
    ])

    unpack = ctx.attr._unpack[platform_common.ToolchainInfo].bin.bin
    ctx.actions.run(
        executable = unpack,
        arguments = [arguments],
        inputs = [archive],
        outputs = [unpatched_dir],
        mnemonic = "WhlInstall",
        progress_message = "Installing wheel for %s" % ctx.label.name,
    )

    # Step 2: Copy and apply patches
    install_dir = ctx.actions.declare_directory("install")

    patch_tool = ctx.file._patch_tool
    patch_files = [f for t in ctx.attr.patches for f in t[DefaultInfo].files.to_list()]

    patch_args = [
        patch_tool.path,
        str(ctx.attr.patch_strip),
        unpatched_dir.path,
        install_dir.path,
    ] + [f.path for f in patch_files]

    ctx.actions.run(
        executable = ctx.file._apply_script,
        arguments = patch_args,
        inputs = [unpatched_dir, patch_tool] + patch_files,
        outputs = [install_dir],
        mnemonic = "WhlApplyPatches",
        progress_message = "Applying %d patch(es) to %s" % (len(patch_files), ctx.label.name),
        use_default_shell_env = True,
    )

    return [
        DefaultInfo(
            files = depset([install_dir]),
            runfiles = ctx.runfiles(files = [install_dir]),
        ),
        PyInfo(
            transitive_sources = depset([install_dir]),
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

whl_apply_patches = rule(
    implementation = _whl_apply_patches,
    doc = """Install a wheel and apply patches to the installed tree.

Combines whl_install (unpacking) and patch application into a single target
that correctly provides PyInfo.""",
    attrs = {
        "src": attr.label(
            mandatory = True,
            doc = "The wheel to install.",
        ),
        "patches": attr.label_list(
            mandatory = True,
            allow_files = [".patch", ".diff"],
            doc = "Patch files to apply after installation.",
        ),
        "patch_strip": attr.int(
            default = 0,
            doc = "Strip count for patches (-p flag).",
        ),
        "_unpack": attr.label(
            default = "//py/private/toolchain:resolved_unpack_toolchain",
            cfg = "exec",
        ),
        "_patch_tool": attr.label(
            default = PATCH_TOOL_LABEL,
            allow_single_file = True,
            cfg = "exec",
        ),
        "_apply_script": attr.label(
            default = "//uv/private/apply_patches:apply_patches.sh",
            allow_single_file = True,
        ),
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
