"""Declaration of concrete toolchains for our Rust tools"""

load(":types.bzl", "PyToolInfo")

def PrebuiltToolConfig(target, cfg):
    """Declare a tool's toolchain configuration.

    Args:
        target: the Bazel target for this tool's binary.
        cfg: one of "target" (runs on the user's machine), "exec" (runs on the
            build host), or "both" (registered under two toolchain types: one
            target_compatible_with for runfiles, one exec_compatible_with for
            build actions).
    """
    if cfg not in ("target", "exec", "both"):
        fail("cfg must be one of 'target', 'exec', or 'both', got: '{}'".format(cfg))
    name = Label(target).name

    toolchain_type = (
        "@aspect_rules_py//py/private/toolchain:{}_toolchain_type".format(name) if cfg in ("target", "both") else None
    )
    exec_toolchain_type = (
        "@aspect_rules_py//py/private/toolchain:{}_exec_toolchain_type".format(name) if cfg in ("exec", "both") else None
    )

    pkg = "@aspect_rules_py//py/private/toolchain/{}".format(name)
    source_toolchains = []
    if cfg in ("target", "both"):
        source_toolchains.append("{pkg}:{name}_source_toolchain".format(pkg = pkg, name = name))
    if cfg in ("exec", "both"):
        source_toolchains.append("{pkg}:{name}_exec_source_toolchain".format(pkg = pkg, name = name))

    return struct(
        target = target,
        name = name,
        source_toolchains = source_toolchains,
        toolchain_type = toolchain_type,
        exec_toolchain_type = exec_toolchain_type,
    )

# The expected config for each tool, whether it runs in an action or at runtime.
# This is the source of truth for toolchain registration and prebuilt downloads.
TOOL_CFGS = [
    PrebuiltToolConfig("//py/tools/unpack:unpack", cfg = "exec"),
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
        vendor_os_abi = "unknown_linux_musl",
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
    ),
    "linux_arm64": struct(
        arch = "aarch64",
        vendor_os_abi = "unknown_linux_musl",
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

source_py_tool_toolchain = rule(
    implementation = _toolchain_impl,
    attrs = {
        "bin": attr.label(
            mandatory = True,
            allow_single_file = True,
            cfg = "target",
        ),
        "template_var": attr.string(
            mandatory = True,
        ),
    },
)

# For exec-side tools: cfg="exec" on bin forces the binary to be compiled for
# the build host. Without it, Bazel analyzes toolchain targets in the caller's
# configuration, causing cross-config contamination (e.g.
# platform_transition_filegroup to a Linux target causes the binary to be
# built for Linux and fail with "cannot execute binary file" on macOS).
source_exec_py_tool_toolchain = rule(
    implementation = _toolchain_impl,
    attrs = {
        "bin": attr.label(
            mandatory = True,
            allow_single_file = True,
            cfg = "exec",
        ),
        "template_var": attr.string(
            mandatory = True,
        ),
    },
)

# Build a lookup dict from tool name → config, sourced from TOOL_CFGS.
_TOOL_CFGS_BY_NAME = {t.name: t for t in TOOL_CFGS}

def source_toolchain(name, bin):
    """Creates source toolchain targets for a tool.

    Args:
        name: The tool name; must match an entry in TOOL_CFGS.
        bin: The rust_binary target.
    """
    tool = _TOOL_CFGS_BY_NAME[name]

    if tool.toolchain_type:
        source_py_tool_toolchain(
            name = "{}_tool".format(name),
            bin = bin,
            template_var = "{}_BIN".format(name.upper()),
        )
        native.toolchain(
            name = "{}_source_toolchain".format(name),
            toolchain = "{}_tool".format(name),
            toolchain_type = tool.toolchain_type,
        )

    if tool.exec_toolchain_type:
        source_exec_py_tool_toolchain(
            name = "{}_exec_tool".format(name),
            bin = bin,
            template_var = "{}_EXEC_BIN".format(name.upper()),
        )
        native.toolchain(
            name = "{}_exec_source_toolchain".format(name),
            toolchain = "{}_exec_tool".format(name),
            toolchain_type = tool.exec_toolchain_type,
        )

def _dummy_toolchain_impl(ctx):
    toolchain_info = platform_common.ToolchainInfo(
        dummy = True,
    )
    return [toolchain_info]

dummy_toolchain = rule(
    implementation = _dummy_toolchain_impl,
    attrs = {
    },
)
