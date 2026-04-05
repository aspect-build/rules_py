"""Declaration of concrete toolchains for our Rust tools"""

load(":types.bzl", "PyToolInfo")

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
    # venv has two toolchain registrations: target-cfg for py_binary runfiles
    # (the binary runs on the user's machine) and exec-cfg for py_venv build
    # actions (the binary creates the venv directory on the exec host).
    PrebuiltToolConfig("//py/tools/venv_bin:venv"),
    PrebuiltToolConfig(
        "//py/tools/venv_bin:venv",
        cfg = "exec",
        name = "venv_exec",
        toolchain_type = "@aspect_rules_py//py/private/toolchain:venv_exec_toolchain_type",
        toolchain = "@aspect_rules_py//py/private/toolchain/venv_exec/...",
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

def source_toolchain(name, toolchain_type, bin):
    """Makes vtool toolchain and repositories

    Args:
        name: Override the prefix for the generated toolchain repositories.
        toolchain_type: Toolchain type reference.
        bin: the rust_binary target
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
