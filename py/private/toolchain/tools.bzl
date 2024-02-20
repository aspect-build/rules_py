"""Toolchain for making toolchains"""

load("//tools:version.bzl", "IS_PRERELEASE")

TOOLCHAIN_PLATFORMS = {
    "darwin_amd64": struct(
        release_platform = "macos-amd64",
        compatible_with = [
            "@platforms//os:macos",
            "@platforms//cpu:x86_64",
        ],
    ),
    "darwin_arm64": struct(
        release_platform = "macos-arm64",
        compatible_with = [
            "@platforms//os:macos",
            "@platforms//cpu:aarch64",
        ],
    ),
    "linux_amd64": struct(
        release_platform = "linux-amd64",
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
    ),
    "linux_arm64": struct(
        release_platform = "linux-arm64",
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:aarch64",
        ],
    ),
}

def _toolchain_impl(ctx):
    binary = ctx.file.bin

    # Make a variable available in places like genrules.
    # See https://docs.bazel.build/versions/main/be/make-variables.html#custom_variables
    template_variables = platform_common.TemplateVariableInfo({
        ctx.attr.template_var: binary.path,
    })
    default_info = DefaultInfo(
        files = depset([binary]),
        runfiles = ctx.runfiles(files = [binary]),
    )

    # Export all the providers inside our ToolchainInfo
    # so the resolved_toolchain rule can grab and re-export them.
    toolchain_info = platform_common.ToolchainInfo(
        bin = binary,
        template_variables = template_variables,
        default_info = default_info,
    )

    return [toolchain_info, default_info, template_variables]

_toolchain = rule(
    implementation = _toolchain_impl,
    attrs = {
        "bin": attr.label(
            mandatory = True,
            allow_single_file = True,
        ),
        "template_var": attr.string(
            mandatory = True,
        ),
    },
)

def _make_toolchain_name(name, platform):
    return "{}_{}_toolchain".format(name, platform)

def make_toolchain(name, toolchain_type, tools, cfg = "exec"):
    """Makes vtool toolchain and repositories

    Args:
        name: Override the prefix for the generated toolchain repositories.
        toolchain_type: Toolchain type reference.
        tools: Mapping of tool binary to platform.
        cfg: Generate a toolchain for the target or exec config.
    """

    # TODO(alex): setup prerelease toolchain when we have rust binaries shipped to GH releases
    # if IS_PRERELEASE:
    #     toolchain_rule = "{}_toolchain_source".format(name)
    #     _toolchain(
    #         name = toolchain_rule,
    #         bin = tools["from-source"],
    #         template_var = "{}_BIN".format(name.upper()),
    #     )
    #     native.toolchain(
    #         name = _make_toolchain_name(name, "source"),
    #         toolchain = toolchain_rule,
    #         toolchain_type = toolchain_type,
    #     )
    #     return

    for [platform, meta] in TOOLCHAIN_PLATFORMS.items():
        toolchain_rule = "{}_toolchain_{}".format(name, platform)
        _toolchain(
            name = toolchain_rule,
            bin = tools[meta.release_platform],
            template_var = "{}_BIN".format(name.upper()),
        )

        args = dict({
            "name": _make_toolchain_name(name, platform),
            "toolchain": toolchain_rule,
            "toolchain_type": toolchain_type,
        })
        if cfg == "exec":
            args.update({"exec_compatible_with": meta.compatible_with})
        else:
            args.update({"target_compatible_with": meta.compatible_with})

        native.toolchain(**args)
