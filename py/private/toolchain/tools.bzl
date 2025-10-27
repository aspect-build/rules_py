"""Declaration of concrete toolchains for our Rust tools"""

load("@bazel_skylib//lib:structs.bzl", "structs")
load(":types.bzl", "PyToolInfo", "VENV_TOOLCHAIN")

def PrebuiltToolConfig(
        target,
        cfg = "target",
        name = None,
        toolchain = None,
        toolchain_type = None):
    name = name or Label(target).name

    # FIXME: The source_toolchain macro creates two targets, so we need to match them both
    # But that makes this not really a label which is weird
    toolchain = toolchain or "@aspect_rules_py//py/private/toolchain/{}/...".format(name)
    toolchain_type = toolchain_type or "@aspect_rules_py//py/private/toolchain:{}_toolchain_type".format(name)

    return struct(
        target = target,
        cfg = cfg,
        name = name,
        toolchain = toolchain,
        toolchain_type = toolchain_type,
    )

# The expected config for each tool, whether it runs in an action or at runtime
#
# Note that this is the source of truth for how toolchains get registered and
# for how they get prebuilt/patched in.
TOOL_CFGS = [
    PrebuiltToolConfig("//py/tools/unpack_bin:unpack", cfg = "exec"),
    PrebuiltToolConfig("//py/tools/venv_bin:venv"),
    PrebuiltToolConfig("//py/tools/venv_shim:shim"),
]

TOOLCHAIN_PLATFORMS = {
    "darwin_amd64": struct(
        arch = "x86_64",
        vendor_os_abi = "apple_darwin",
        compatible_with = [
            "@platforms//os:macos",
            "@platforms//cpu:x86_64",
        ],
    ),
    "darwin_arm64": struct(
        arch = "aarch64",
        vendor_os_abi = "apple_darwin",
        compatible_with = [
            "@platforms//os:macos",
            "@platforms//cpu:aarch64",
        ],
    ),
    "linux_amd64": struct(
        arch = "x86_64",
        vendor_os_abi = "unknown_linux_gnu",
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
    ),
    "linux_arm64": struct(
        arch = "aarch64",
        vendor_os_abi = "unknown_linux_gnu",
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
        bin = PyToolInfo(bin = binary),
        template_variables = template_variables,
        default_info = default_info,
    )

    return [toolchain_info, default_info, template_variables]

py_tool_toolchain = rule(
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

def source_toolchain(name, toolchain_type, bin):
    """Makes vtool toolchain and repositories

    Args:
        name: Override the prefix for the generated toolchain repositories.
        toolchain_type: Toolchain type reference.
        bin: the rust_binary target
    """

    toolchain_rule = "{}_toolchain_source".format(name)
    py_tool_toolchain(
        name = toolchain_rule,
        bin = bin,
        template_var = "{}_BIN".format(name.upper()),
    )
    native.toolchain(
        name = "{}_source_toolchain".format(name),
        toolchain = toolchain_rule,
        toolchain_type = toolchain_type,
    )

# Forward all the providers
def _resolved_toolchain_impl(ctx):
    toolchain_info = ctx.toolchains[VENV_TOOLCHAIN]
    return [toolchain_info] + structs.to_dict(toolchain_info).values()

# Copied from java_toolchain_alias
# https://cs.opensource.google/bazel/bazel/+/master:tools/jdk/java_toolchain_alias.bzl
resolved_venv_toolchain = rule(
    implementation = _resolved_toolchain_impl,
    toolchains = [VENV_TOOLCHAIN],
)
