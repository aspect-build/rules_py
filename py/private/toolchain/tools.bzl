"""Toolchain platform definitions and sentinel toolchain rule."""

TOOLCHAIN_PLATFORMS = {
    "darwin_amd64": struct(
        compatible_with = [
            "@platforms//os:macos",
            "@platforms//cpu:x86_64",
        ],
    ),
    "darwin_arm64": struct(
        compatible_with = [
            "@platforms//os:macos",
            "@platforms//cpu:aarch64",
        ],
    ),
    "linux_amd64": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
    ),
    "linux_arm64": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:aarch64",
        ],
    ),
}

def _dummy_toolchain_impl(ctx):
    toolchain_info = platform_common.ToolchainInfo(
        dummy = True,
    )
    return [toolchain_info]

dummy_toolchain = rule(
    implementation = _dummy_toolchain_impl,
    attrs = {},
)

def _venv_symlink_toolchain_impl(ctx):
    tool = ctx.attr.tool[DefaultInfo].files_to_run if ctx.attr.tool else None
    return [platform_common.ToolchainInfo(tool = tool)]

venv_symlink_toolchain = rule(
    doc = "Declares a venv site-packages symlink tool or a native-symlink fallback.",
    implementation = _venv_symlink_toolchain_impl,
    attrs = {
        "tool": attr.label(
            cfg = "exec",
            doc = """Executable that receives a parameter-file path as its only argument.
The file contains alternating output and relative-target lines. The tool
creates parent directories and materializes the unresolved symlinks. Omit to
use native symlink actions.""",
            executable = True,
        ),
    },
)
