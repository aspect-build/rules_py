"""Synthetic C++ toolchains for the PEP 517 execution-group test."""

def _fake_cc_toolchain_impl(ctx):
    compiler = ctx.file.compiler
    return [
        platform_common.ToolchainInfo(
            all_files = depset([compiler]),
            compiler_executable = compiler.path,
        ),
    ]

fake_cc_toolchain = rule(
    implementation = _fake_cc_toolchain_impl,
    attrs = {
        "compiler": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
    },
)
