"""Rust rule defaults"""

load("@rules_rust//rust:defs.bzl", _rust_binary = "rust_binary")
load("@with_cfg.bzl", "with_cfg")

_default_platform = select({
    # Non-Linux binaries should just build with their default platforms
    "//conditions:default": None,
})

rust_opt_binary, _rust_opt_binary_internal = with_cfg(_rust_binary).set(
    "compilation_mode",
    "opt",
).set(
    Label("@rules_rust//:extra_rustc_flags"),
    [
        "-Cstrip=symbols",
        "-Ccodegen-units=1",
        "-Cpanic=abort",
    ],
    # Avoid rules_rust trying to instrument this binary
).set("collect_code_coverage", "false").build()

def rust_binary(name, platform = _default_platform, **kwargs):
    """
    Macro for rust_binary defaults.

    Args:
        name: Name of the rust_binary target
        platform: optional platform to transition to
        **kwargs: Additional args to pass to rust_binary
    """

    # Note that we use symbol stripping to
    # try and make these artifacts reproducibly sized for the
    # container_structure tests.
    rust_opt_binary(
        name = name,
        platform = platform,
        **kwargs
    )
