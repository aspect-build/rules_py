"""Test-only exec-tools toolchain wrapping a self-contained unpack binary.

Mirrors what a user registering a custom `unpack_tool` writes today: the
toolchain resolves the standard Python toolchain type for its runtime payloads
(safe — this target is registered only under the exec-tools type, so that
resolution cannot cycle back into it) and exposes the binary as the opaque
`unpack_tool` struct consumed by PyUnpackedWheel/WhlInstall actions.
"""

PY_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"

def _custom_unpack_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(
        exec_runtime = ctx.toolchains[PY_TOOLCHAIN].py3_runtime,
        unpack_tool = struct(
            executable = ctx.attr.unpack_tool[DefaultInfo].files_to_run,
            arguments = [],
            inputs = depset(),
        ),
    )]

custom_unpack_toolchain = rule(
    implementation = _custom_unpack_toolchain_impl,
    attrs = {
        "unpack_tool": attr.label(
            doc = "Self-contained executable implementing the unpack CLI contract.",
            executable = True,
            cfg = "target",
            mandatory = True,
        ),
    },
    toolchains = [PY_TOOLCHAIN],
)
