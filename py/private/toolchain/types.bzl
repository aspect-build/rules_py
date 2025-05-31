"""Constants & types for toolchains"""

PY_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"
SH_TOOLCHAIN = "@bazel_tools//tools/sh:toolchain_type"

# Toolchain type for the virtual env creation tools.
SHIM_TOOLCHAIN = "@aspect_rules_py//py/private/toolchain:shim_toolchain_type"
UNPACK_TOOLCHAIN = "@aspect_rules_py//py/private/toolchain:unpack_toolchain_type"
VENV_TOOLCHAIN = "@aspect_rules_py//py/private/toolchain:venv_toolchain_type"

PyToolInfo = provider(
    doc = "An info so we don't just return bare files",
    fields = {
        "bin": "A binary file",
    },
)
