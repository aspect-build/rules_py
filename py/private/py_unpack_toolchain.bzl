"""The wheel-unpack tool behind `WhlInstall` and `PyUnpackedWheel` actions.

A registered `py_unpack_toolchain` replaces the default, which runs
//py/tools/unpack under the exec-tools interpreter. Both toolchain types are
resolved together, so the tool and the `--compile-pyc` interpreter share one
execution platform.
"""

load("//py/private:py_source_tool.bzl", "PySourceToolInfo")
load("//py/private/toolchain:types.bzl", "EXEC_TOOLS_TOOLCHAIN", "UNPACK_TOOLCHAIN")

UNPACK_TOOLCHAINS = [
    EXEC_TOOLS_TOOLCHAIN,
    config_common.toolchain_type(UNPACK_TOOLCHAIN, mandatory = False),
]

UNPACK_ATTRS = {
    "_unpack": attr.label(
        default = "//py/tools/unpack",
        providers = [PySourceToolInfo],
    ),
}

def resolve_unpack_tool(ctx):
    """The unpack tool for a rule declaring `UNPACK_TOOLCHAINS` and `UNPACK_ATTRS`.

    Args:
        ctx: rule context.

    Returns:
        struct(executable, arguments, inputs) for `ctx.actions.run`; callers
        append the unpack CLI flags to `arguments`.
    """
    custom = ctx.toolchains[UNPACK_TOOLCHAIN]
    if custom:
        return struct(
            executable = custom.unpack_tool,
            arguments = [],
            inputs = depset(),
        )

    exec_runtime = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN].exec_runtime
    default_tool = ctx.attr._unpack[PySourceToolInfo]
    return struct(
        executable = exec_runtime.interpreter,
        arguments = ["-S", "-E", "-s", "-B", default_tool.main],
        inputs = depset(
            [exec_runtime.interpreter],
            transitive = [default_tool.files, exec_runtime.files],
        ),
    )

def _py_unpack_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(
        unpack_tool = ctx.attr.tool[DefaultInfo].files_to_run,
    )]

py_unpack_toolchain = rule(
    implementation = _py_unpack_toolchain_impl,
    doc = """Replaces the default wheel-unpack tool.

Register it under `@aspect_rules_py//py:unpack_toolchain_type`. The tool must
implement the unpack CLI contract; see "Custom wheel-unpack tool" in
docs/interpreter.md.
""",
    attrs = {
        "tool": attr.label(
            doc = "Executable implementing the unpack CLI contract.",
            executable = True,
            cfg = "exec",
            mandatory = True,
        ),
    },
)
