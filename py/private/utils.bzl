PY_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"
SH_TOOLCHAIN = "@bazel_tools//tools/sh:toolchain_type"

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

    if py3_toolchain.interpreter != None:
        files = depset([py3_toolchain.interpreter], transitive = [py3_toolchain.files])
    else:
        files = py3_toolchain.files

    return struct(
        toolchain = py3_toolchain,
        files = files,
        python = py3_toolchain.interpreter,
        flags = ["-B", "-s", "-I"],
    )
