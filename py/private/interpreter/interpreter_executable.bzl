"""Expose a supplied Python runtime pair as an executable target."""

def _interpreter_executable_impl(ctx):
    toolchain = ctx.attr.runtime_pair[platform_common.ToolchainInfo]
    runtime = toolchain.py3_runtime
    if runtime.interpreter == None:
        fail("interpreter_executable requires a hermetic Python runtime")

    # rules_python's default exec_interpreter resolves its Python toolchain in
    # cfg = "exec". PBS repositories instead need to preserve their supplied
    # runtime pair while satisfying exec_interpreter's executable contract:
    # https://github.com/bazel-contrib/rules_python/blob/1.9.0/python/private/py_exec_tools_toolchain.bzl#L61-L106
    # Keep the executable symlink shape used by rules_python's own adapter:
    # https://github.com/bazel-contrib/rules_python/blob/1.9.0/python/private/py_exec_tools_toolchain.bzl#L108-L129
    executable = ctx.actions.declare_file(
        "{}/{}".format(ctx.label.name, runtime.interpreter.basename),
    )
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
