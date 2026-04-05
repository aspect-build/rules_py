"""Declaration of concrete toolchains for our Rust tools"""

load(":types.bzl", "PyToolInfo")

def PrebuiltToolConfig(
        target,
        cfg = "target",
        name = None,
        toolchain = None,
        toolchain_type = None,
        exec_toolchain_type = None):
    name = name or Label(target).name

    # The source_toolchain macro creates two targets per cfg; the glob matches both.
    toolchain = toolchain or "@aspect_rules_py//py/private/toolchain/{}/...".format(name)
    toolchain_type = toolchain_type or "@aspect_rules_py//py/private/toolchain:{}_toolchain_type".format(name)

    return struct(
        target = target,
        cfg = cfg,
        name = name,
        toolchain = toolchain,
        toolchain_type = toolchain_type,
        exec_toolchain_type = exec_toolchain_type,
    )

# The expected config for each tool, whether it runs in an action or at runtime.
#
# This is the source of truth for how toolchains get registered and how they
# get prebuilt/patched in.
#
# Tools with exec_toolchain_type set register under two toolchain types from a
# single binary: target_compatible_with for the primary type (binary runs on
# the user's machine) and exec_compatible_with for the exec type (binary runs
# on the build host).
TOOL_CFGS = [
    PrebuiltToolConfig("//py/tools/unpack_bin:unpack", cfg = "exec"),
    PrebuiltToolConfig(
        "//py/tools/venv_bin:venv",
        exec_toolchain_type = "@aspect_rules_py//py/private/toolchain:venv_exec_toolchain_type",
    ),
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

source_target_py_tool_toolchain = rule(
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

# Build a lookup dict from tool name → cfg, sourced from TOOL_CFGS.
_TOOL_CFGS_BY_NAME = {t.name: t for t in TOOL_CFGS}

def source_toolchain(name, toolchain_type, bin, exec_toolchain_type = None):
    """Creates source toolchain targets for a tool.

    Args:
        name: The tool name; must match an entry in TOOL_CFGS.
        toolchain_type: Toolchain type label for the primary (target-cfg) registration.
        bin: The rust_binary target.
        exec_toolchain_type: If set, also creates an exec-cfg toolchain registered
            under this type. Used for tools that run both on the user's machine
            (target cfg) and as build actions on the exec host (exec cfg).
    """

    # Use cfg from TOOL_CFGS as the single source of truth: tools registered
    # with cfg="exec" (e.g. unpack) get source_exec_py_tool_toolchain so the
    # binary is built for the exec host even when the target platform differs.
    tool_rule = source_exec_py_tool_toolchain if _TOOL_CFGS_BY_NAME[name].cfg == "exec" else source_target_py_tool_toolchain
    toolchain_rule = "{}_toolchain_source".format(name)
    tool_rule(
        name = toolchain_rule,
        bin = bin,
        template_var = "{}_BIN".format(name.upper()),
    )
    native.toolchain(
        name = "{}_source_toolchain".format(name),
        toolchain = toolchain_rule,
        toolchain_type = toolchain_type,
    )

    if exec_toolchain_type:
        exec_toolchain_rule = "{}_exec_toolchain_source".format(name)
        source_exec_py_tool_toolchain(
            name = exec_toolchain_rule,
            bin = bin,
            template_var = "{}_EXEC_BIN".format(name.upper()),
        )
        native.toolchain(
            name = "{}_exec_source_toolchain".format(name),
            toolchain = exec_toolchain_rule,
            toolchain_type = exec_toolchain_type,
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
