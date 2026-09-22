"""Builds `pep517_native_whl` variants whose Rust toolchain joins the exec group.

Bazel resolves each execution group independently. The plain `pep517_native_whl`
receives its Rust toolchain through a target-configured `toolchains` label (and a
`cfg = "exec"` sysroot proxy), so under multiple registered execution platforms
that selection can disagree with the platform `TARGET_EXEC_GROUP` picks for the
wheel action. Instances returned by `make_rust_native_whl_rule()` resolve the
Rust toolchain type *inside* `TARGET_EXEC_GROUP`, forcing one platform choice
for the action, its cargo/rustc binaries, and the host std.

The toolchain type label is injected by the caller (sdist_build generates a
three-line .bzl in each sdist's repository): rules_py itself must stay free of
any static `@rules_rust` reference, which would break analysis of every native
sdist build for consumers that declare no rules_rust.
"""

load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")
load(
    ":common.bzl",
    "TARGET_EXEC_GROUP",
)
load(
    ":pep517_native_whl.bzl",
    "PEP517_NATIVE_WHL_ATTRS",
    "TARGET_EXEC_GROUP_TYPES",
    "pep517_native_whl_impl",
)

def make_rust_native_whl_rule(rust_toolchain_type):
    """Return a `pep517_native_whl` rule resolving `rust_toolchain_type` in TARGET_EXEC_GROUP.

    Args:
        rust_toolchain_type: the toolchain type Label (e.g. rules_rust's
            `//rust:toolchain_type`, spelled canonically) to resolve inside the
            wheel action's execution group. Optional there: when no toolchain of
            the type registers, the rule falls back to the target-configured
            `toolchains` label exactly like the plain `pep517_native_whl`.

    Returns:
        A rule with `pep517_native_whl`'s attributes whose action sources
        CARGO/RUSTC/RUST_SYSROOT/RUST_HOST_SYSROOT from the exec group's
        resolution when one resolved.
    """

    def _impl(ctx):
        eg_toolchains = ctx.exec_groups[TARGET_EXEC_GROUP].toolchains
        return pep517_native_whl_impl(ctx, exec_group_rust_toolchain = eg_toolchains[rust_toolchain_type])

    return rule(
        implementation = _impl,
        doc = """PEP 517 sdist to platform-specific whl build rule, with the Rust toolchain tied to the wheel action's execution platform.

Identical to `pep517_native_whl`, plus the Rust toolchain type resolves inside
the same execution group the build action runs in, so cargo, rustc, and the
host std always come from the platform executing the wheel build.

""",
        attrs = PEP517_NATIVE_WHL_ATTRS,
        fragments = ["cpp"],
        toolchains = [
            config_common.toolchain_type(PY_TOOLCHAIN, mandatory = False),
        ],
        exec_groups = {
            TARGET_EXEC_GROUP: exec_group(
                toolchains = TARGET_EXEC_GROUP_TYPES + [
                    config_common.toolchain_type(rust_toolchain_type, mandatory = False),
                ],
            ),
        },
    )
