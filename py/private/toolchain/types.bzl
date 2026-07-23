"""Constants for toolchain types"""

PY_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"
EXEC_TOOLS_TOOLCHAIN = "@aspect_rules_py//py/private/toolchain:exec_tools_toolchain_type"
NATIVE_BUILD_TOOLCHAIN = "@aspect_rules_py//py/private/toolchain:native_build_toolchain_type"

def interpreter_files_and_version(toolchain):
    """Interpreter files and version from a resolved PY_TOOLCHAIN target.

    Reads the target's `ToolchainInfo.py3_runtime`, so the result tracks the
    consumer's Python version transition.

    Args:
        toolchain: a resolved PY_TOOLCHAIN target carrying `ToolchainInfo`.

    Returns:
        `(depset[File] | None, struct(major, minor, micro) | None)`. `None`
        files means the toolchain has no usable py3 runtime; the caller should
        skip the node.
    """
    py3 = getattr(toolchain[platform_common.ToolchainInfo], "py3_runtime", None)
    if py3 == None or py3.files == None:
        return None, None
    direct = [py3.interpreter] if getattr(py3, "interpreter", None) != None else []
    files = depset(direct = direct, transitive = [py3.files])
    vi = getattr(py3, "interpreter_version_info", None)
    version = struct(major = vi.major, minor = vi.minor, micro = vi.micro) if vi != None else None
    return files, version
