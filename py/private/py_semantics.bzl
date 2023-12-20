"""Functions to determine which Python toolchain to use"""

load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")

_INTERPRETER_FLAGS = ["-B", "-I"]

def _resolve_toolchain(ctx):
    """Resolves the Python toolchain to a simple struct.

    Args:
        ctx: Bazel rule context.

    Returns:
        Struct describing the Python toolchain to use.
    """

    toolchain_info = ctx.toolchains[PY_TOOLCHAIN]

    if not toolchain_info.py3_runtime:
        fail("A py3_runtime must be set on the Python toolchain")

    py3_toolchain = toolchain_info.py3_runtime

    interpreter = None
    uses_interpreter_path = False

    if py3_toolchain.interpreter != None:
        files = depset([py3_toolchain.interpreter], transitive = [py3_toolchain.files])
        interpreter = py3_toolchain.interpreter
    else:
        files = py3_toolchain.files
        interpreter = struct(
            path = py3_toolchain.interpreter_path,
            short_path = py3_toolchain.interpreter_path,
        )
        files = depset([])
        uses_interpreter_path = True

    return struct(
        toolchain = py3_toolchain,
        files = files,
        python = interpreter,
        uses_interpreter_path = uses_interpreter_path,
        flags = _INTERPRETER_FLAGS,
    )

semantics = struct(
    interpreter_flags = _INTERPRETER_FLAGS,
    resolve_toolchain = _resolve_toolchain,
)
