"""Writes the interpreter symlinks the resolved Python toolchain recorded."""

def _toolchain_symlinks_impl(ctx):
    toolchain = ctx.toolchains["@bazel_tools//tools/python:toolchain_type"]
    out = ctx.actions.declare_file(ctx.label.name + ".json")
    ctx.actions.write(out, json.encode(getattr(toolchain, "interpreter_symlinks", {})))
    return [DefaultInfo(files = depset([out]))]

toolchain_symlinks = rule(
    implementation = _toolchain_symlinks_impl,
    toolchains = ["@bazel_tools//tools/python:toolchain_type"],
)
