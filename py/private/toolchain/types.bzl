"""Constants for toolchain types"""

PY_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"
EXEC_TOOLS_TOOLCHAIN = "@rules_python//python:exec_tools_toolchain_type"
NATIVE_BUILD_TOOLCHAIN = "@aspect_rules_py//py/private/toolchain:native_build_toolchain_type"
VENV_SYMLINK_TOOLCHAIN = "@aspect_rules_py//py/private/toolchain:venv_symlink_toolchain_type"
