"""Synthetic C++ toolchains for the PEP 517 execution-group test."""

load("@rules_cc//cc:cc_toolchain_config_lib.bzl", "feature", "tool_path")  # buildifier: disable=deprecated-function
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/toolchains:cc_toolchain_config_info.bzl", "CcToolchainConfigInfo")

def _fake_cc_toolchain_impl(ctx):
    compiler = ctx.file.compiler
    return [
        platform_common.ToolchainInfo(
            all_files = depset([compiler] + ctx.files.tools),
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
        "tools": attr.label_list(allow_files = True),
    },
)

def _legacy_cc_toolchain_config_impl(ctx):
    compiler = ctx.file.compiler.basename
    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        toolchain_identifier = "legacy-no-action-configs",
        host_system_name = "local",
        target_system_name = "local",
        target_cpu = "x86_64",
        target_libc = "unknown",
        compiler = "legacy",
        abi_version = "unknown",
        abi_libc_version = "unknown",
        features = [feature(name = "no_legacy_features", enabled = True)],
        tool_paths = [
            tool_path(name = "ar", path = ctx.file.archiver.basename),
            tool_path(name = "cpp", path = compiler),
            tool_path(name = "dwp", path = compiler),
            tool_path(name = "gcc", path = compiler),
            tool_path(name = "gcov", path = compiler),
            tool_path(name = "ld", path = compiler),
            tool_path(name = "nm", path = compiler),
            tool_path(name = "objcopy", path = compiler),
            tool_path(name = "objdump", path = compiler),
            tool_path(name = "strip", path = compiler),
        ],
    )

legacy_cc_toolchain_config = rule(
    implementation = _legacy_cc_toolchain_config_impl,
    attrs = {
        "archiver": attr.label(allow_single_file = True, mandatory = True),
        "compiler": attr.label(allow_single_file = True, mandatory = True),
    },
    provides = [CcToolchainConfigInfo],
)
