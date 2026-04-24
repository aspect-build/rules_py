"""Constants & types for UV toolchains"""

UV_TOOLCHAIN = "@aspect_rules_py//uv/private/toolchain:toolchain_type"

UvToolInfo = provider(
    doc = "Provider for the UV toolchain",
    fields = {
        "bin": "The UV binary file",
    },
)

def _uv_tool_toolchain_impl(ctx):
    binary = ctx.file.bin
    toolchain_info = platform_common.ToolchainInfo(
        uvinfo = UvToolInfo(bin = binary),
    )
    return [toolchain_info]

uv_tool_toolchain = rule(
    implementation = _uv_tool_toolchain_impl,
    attrs = {
        "bin": attr.label(
            mandatory = True,
            allow_single_file = True,
        ),
    },
)
