"""A fake target Python toolchain whose runtime has no in-build interpreter.

Emits the standard `@bazel_tools//tools/python:toolchain_type` payload with a
`py3_runtime` that carries only an `interpreter_path` (a system interpreter),
no in-build `interpreter` file. Built as a plain struct so the fixture depends
on neither rules_python's `py_runtime`/`py_runtime_pair` nor any `PyRuntimeInfo`
provider symbol.
"""

def _system_runtime_impl(ctx):
    runtime = struct(
        interpreter = None,
        interpreter_path = ctx.attr.interpreter_path,
        interpreter_version_info = struct(major = "3", minor = "94", micro = "0"),
        files = depset(),
    )
    return [platform_common.ToolchainInfo(py2_runtime = None, py3_runtime = runtime)]

system_runtime = rule(
    implementation = _system_runtime_impl,
    attrs = {"interpreter_path": attr.string(mandatory = True)},
)
