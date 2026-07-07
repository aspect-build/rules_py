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
