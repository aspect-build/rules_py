"""Checks selected Python runtime and exec-tools toolchains."""

_RUNTIME_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"
_EXEC_TOOLS_TOOLCHAIN = "@rules_python//python:exec_tools_toolchain_type"

_EXEC_INTERPRETER_CHECK = """\
import os
import pathlib
import sys
import sysconfig

expected_version = tuple(map(int, sys.argv[1].split(".")))
expected_freethreaded = sys.argv[2] == "1"
expected_interpreter = sys.argv[3]

if not os.path.samefile(sys.executable, expected_interpreter):
    raise SystemExit(
        f"expected interpreter {expected_interpreter}, got {sys.executable}"
    )
if sys.version_info[:2] != expected_version:
    raise SystemExit(
        f"expected Python {expected_version}, got {sys.version_info[:2]}"
    )
actual_freethreaded = bool(sysconfig.get_config_var("Py_GIL_DISABLED"))
if actual_freethreaded != expected_freethreaded:
    raise SystemExit(
        f"expected free-threaded={expected_freethreaded}, "
        f"got {actual_freethreaded}"
    )

pathlib.Path(sys.argv[4]).touch()
"""

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

def _exec_toolchain_check_impl(ctx):
    exec_tools = ctx.toolchains[_EXEC_TOOLS_TOOLCHAIN].exec_tools
    if exec_tools.exec_interpreter == None:
        fail("PBS exec toolchain has no interpreter")
    if exec_tools.exec_runtime == None:
        fail("PBS exec toolchain has no runtime")
    if exec_tools.exec_runtime.interpreter != ctx.file.expected_interpreter:
        fail(
            "expected PBS exec runtime {}, got {}".format(
                ctx.file.expected_interpreter,
                exec_tools.exec_runtime.interpreter,
            ),
        )

    output = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.run(
        arguments = [
            "-c",
            _EXEC_INTERPRETER_CHECK,
            ctx.attr.python_version,
            "1" if ctx.attr.freethreaded else "0",
            ctx.file.expected_interpreter.path,
            output.path,
        ],
        executable = exec_tools.exec_interpreter[DefaultInfo].files_to_run,
        inputs = [ctx.file.expected_interpreter],
        mnemonic = "ExecInterpreterSmoke",
        outputs = [output],
    )
    return [DefaultInfo(files = depset([output]))]

exec_toolchain_check = rule(
    implementation = _exec_toolchain_check_impl,
    attrs = {
        "expected_interpreter": attr.label(allow_single_file = True, mandatory = True),
        "freethreaded": attr.bool(),
        "python_version": attr.string(mandatory = True),
    },
    toolchains = [_EXEC_TOOLS_TOOLCHAIN],
)
