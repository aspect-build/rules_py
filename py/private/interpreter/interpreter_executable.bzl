"""Expose a specific Python runtime pair without resolving another toolchain."""

def _interpreter_executable_impl(ctx):
    toolchain = ctx.attr.runtime_pair[platform_common.ToolchainInfo]
    runtime = toolchain.py3_runtime
    if runtime.interpreter == None:
        fail("interpreter_executable requires a hermetic Python runtime")

    # py_exec_tools_toolchain's default resolves the Python toolchain again in
    # cfg = "exec", which would couple target_compatible_with to the executor:
    # https://github.com/bazel-contrib/rules_python/blob/1.9.1/python/private/py_exec_tools_toolchain.bzl#L61-L73
    executable = ctx.actions.declare_file(runtime.interpreter.basename)
    ctx.actions.symlink(
        output = executable,
        target_file = runtime.interpreter,
        is_executable = True,
    )
    return [
        toolchain,
        DefaultInfo(
            executable = executable,
            runfiles = ctx.runfiles(
                files = [executable],
                transitive_files = runtime.files,
            ),
        ),
    ]

interpreter_executable = rule(
    implementation = _interpreter_executable_impl,
    attrs = {
        "runtime_pair": attr.label(
            mandatory = True,
            providers = [platform_common.ToolchainInfo],
        ),
    },
    executable = True,
)
