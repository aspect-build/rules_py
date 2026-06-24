"""Analysis check for the selected Python runtime toolchain."""

_RUNTIME_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"

def _interpreter_toolchain_check_impl(ctx):
    runtime = ctx.toolchains[_RUNTIME_TOOLCHAIN].py3_runtime
    if runtime == None:
        fail("Python {} runtime toolchain was not resolved".format(ctx.attr.python_version))
    if runtime.interpreter == None:
        fail("Python {} runtime toolchain is not hermetic".format(ctx.attr.python_version))
    if runtime.interpreter != ctx.file.expected_interpreter:
        fail(
            "expected Python {} PBS interpreter {}, got {}".format(
                ctx.attr.python_version,
                ctx.file.expected_interpreter,
                runtime.interpreter,
            ),
        )

    version_info = runtime.interpreter_version_info
    actual = "{}.{}".format(version_info.major, version_info.minor)
    if actual != ctx.attr.python_version:
        fail("expected Python {} runtime, got {}".format(ctx.attr.python_version, actual))
    return []

interpreter_toolchain_check = rule(
    implementation = _interpreter_toolchain_check_impl,
    attrs = {
        "expected_interpreter": attr.label(allow_single_file = True, mandatory = True),
        "python_version": attr.string(mandatory = True),
    },
    toolchains = [_RUNTIME_TOOLCHAIN],
)
