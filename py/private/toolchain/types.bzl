"""Constants & types for toolchains"""

PY_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"
SH_TOOLCHAIN = "@bazel_tools//tools/sh:toolchain_type"
EXEC_TOOLS_TOOLCHAIN = "@aspect_rules_py//py/private/toolchain:exec_tools_toolchain_type"
UNPACK_TOOLCHAIN = "@aspect_rules_py//py/private/toolchain:unpack_exec_toolchain_type"
NATIVE_BUILD_TOOLCHAIN = "@aspect_rules_py//py/private/toolchain:native_build_toolchain_type"

PyToolInfo = provider(
    doc = "An info so we don't just return bare files",
    fields = {
        "bin": "A binary file",
    },
)
