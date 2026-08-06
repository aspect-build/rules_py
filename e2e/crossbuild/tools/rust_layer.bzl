"""Exposes a specific (non-ambient-resolved) rust_toolchain's sysroot.

`@rules_rust//rust/toolchain:current_rust_toolchain` resolves against the
build's ambient --platforms, so under a cross (arm64) transition it returns
the arm64-*targeting* toolchain — whose sysroot only carries LLVM's shared
libs for x86_64, not the x86_64 rust-std a build script/proc-macro (always
compiled for the exec platform) needs. This rule instead pins to a specific
`rust_toolchain` target by label, bypassing toolchain resolution entirely,
so a package can also pull in the plain x86_64-targeting toolchain's sysroot
regardless of which platform the rest of the build is transitioned to.
"""

def _rust_pinned_sysroot_impl(ctx):
    toolchain = ctx.attr.actual[platform_common.ToolchainInfo]
    return [
        DefaultInfo(files = toolchain.all_files),
        platform_common.TemplateVariableInfo({
            "RUST_HOST_SYSROOT": toolchain.sysroot,
        }),
    ]

rust_pinned_sysroot = rule(
    implementation = _rust_pinned_sysroot_impl,
    attrs = {
        "actual": attr.label(
            doc = "A rust_toolchain target (not a toolchain_type alias) to pin to.",
            mandatory = True,
        ),
    },
    doc = "Exposes `actual`'s sysroot as $(RUST_HOST_SYSROOT), bypassing toolchain resolution.",
)
