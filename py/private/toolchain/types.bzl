"""Constants & types for toolchains"""

PY_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"
SH_TOOLCHAIN = "@bazel_tools//tools/sh:toolchain_type"
EXEC_TOOLS_TOOLCHAIN = "@aspect_rules_py//py/private/toolchain:exec_tools_toolchain_type"

# Toolchain type for the virtual env creation tools.
SHIM_TOOLCHAIN = "@aspect_rules_py//py/private/toolchain:shim_toolchain_type"
UNPACK_TOOLCHAIN = "@aspect_rules_py//py/private/toolchain:unpack_exec_toolchain_type"
VENV_TARGET_TOOLCHAIN = "@aspect_rules_py//py/private/toolchain:venv_toolchain_type"

# Exec-configured variant of the venv tool: used for build actions that run
# the venv binary on the exec host (e.g. creating the venv directory).
VENV_EXEC_TOOLCHAIN = "@aspect_rules_py//py/private/toolchain:venv_exec_toolchain_type"
TARGET_EXEC_TOOLCHAIN = "@aspect_rules_py//py/private/toolchain:target_exec_toolchain_type"

PyToolInfo = provider(
    doc = "An info so we don't just return bare files",
    fields = {
        "bin": "A binary file",
    },
)
