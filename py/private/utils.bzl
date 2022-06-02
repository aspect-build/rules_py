PY_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"
SH_TOOLCHAIN = "@bazel_tools//tools/sh:toolchain_type"

INTERPRETER_FLAGS = ["-B", "-s", "-I"]

def dict_to_exports(env):
    return [
        "export %s=\"%s\"" % (k, v)
        for (k, v) in env.items()
    ]

def resolve_toolchain(ctx):
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
        flags = INTERPRETER_FLAGS,
    )
