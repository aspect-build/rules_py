"""Exposes the host-targeting rust_toolchain's sysroot.

`@rules_rust//rust/toolchain:current_rust_toolchain` resolves against the
build's ambient --platforms, so under a cross (arm64) transition it returns
the arm64-*targeting* toolchain — whose sysroot only carries LLVM's shared
libs for the exec platform, not the exec platform's rust-std a build
script/proc-macro (always compiled for the exec platform) needs. This rule
re-resolves it under rules_py's exec_transition (--platforms := the host
platform), which hands back the host-*targeting* toolchain on any host —
x86_64-linux on the CI runner, aarch64-darwin on a macOS workstation —
without hardcoding either repository's label.
"""

load("@aspect_rules_py//uv/private/pep517_whl:exec_transition.bzl", "exec_transition")

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
            cfg = exec_transition,
            doc = "current_rust_toolchain, re-resolved with --platforms set to the host.",
            mandatory = True,
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Exposes the host-targeting rust_toolchain's sysroot as $(RUST_HOST_SYSROOT).",
)
