"""Exposes the exec-platform rust_toolchain's sysroot.

`@rules_rust//rust/toolchain:current_rust_toolchain` resolves against the
build's ambient --platforms, so under a cross transition it returns the
*target*-targeting toolchain — whose sysroot has no exec-platform rust-std,
which build scripts/proc-macros (always compiled for the exec platform)
need. Re-resolving the toolchain in the exec configuration hands back the
exec-targeting toolchain without hardcoding any repository label.
"""

def _rust_host_sysroot_impl(ctx):
    actual = ctx.attr.actual
    if type(actual) == "list":
        actual = actual[0]
    toolchain = actual[platform_common.ToolchainInfo]
    return [
        DefaultInfo(files = toolchain.all_files),
        platform_common.TemplateVariableInfo({
            "RUST_HOST_SYSROOT": toolchain.sysroot,
        }),
    ]

rust_host_sysroot = rule(
    implementation = _rust_host_sysroot_impl,
    attrs = {
        "actual": attr.label(
            cfg = "exec",
            doc = "current_rust_toolchain, re-resolved in the exec configuration.",
            mandatory = True,
        ),
    },
    doc = "Exposes the exec-platform rust_toolchain's sysroot as $(RUST_HOST_SYSROOT).",
)
