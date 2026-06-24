"""Checks selected Python runtime and exec-tools toolchains."""

load("@bazel_skylib//rules:build_test.bzl", "build_test")

# Python runtimes use Bazel's standard toolchain contract. The separate
# build-time interpreter contract is public API supplied by rules_python.
_RUNTIME_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"
_EXEC_TOOLS_TOOLCHAIN = "@rules_python//python:exec_tools_toolchain_type"

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
            ctx.file._exec_interpreter_check.path,
            ctx.attr.python_version,
            "1" if ctx.attr.freethreaded else "0",
            ctx.file.expected_interpreter.path,
            output.path,
        ],
        executable = exec_tools.exec_interpreter[DefaultInfo].files_to_run,
        inputs = [ctx.file._exec_interpreter_check, ctx.file.expected_interpreter],
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
        "_exec_interpreter_check": attr.label(
            allow_single_file = True,
            default = ":exec_interpreter_check.py",
        ),
    },
    toolchains = [_EXEC_TOOLS_TOOLCHAIN],
)

def _toolchain_test_transition_impl(_settings, attr):
    return {
        "//:interpreter_setting": attr.interpreter_setting,
        "//:interpreter_setting_secondary": attr.interpreter_setting_secondary,
        "//command_line_option:extra_execution_platforms": [str(attr.execution_platform)],
        "//command_line_option:platforms": [str(attr.target_platform)],
        "@aspect_rules_py//py/private/interpreter:freethreaded": attr.freethreaded,
        "@aspect_rules_py//py:python_version": attr.python_version,
        "@aspect_rules_py//uv/private/constraints/platform:platform_libc": attr.libc,
    }

_toolchain_test_transition = transition(
    implementation = _toolchain_test_transition_impl,
    inputs = [],
    outputs = [
        "//:interpreter_setting",
        "//:interpreter_setting_secondary",
        "//command_line_option:extra_execution_platforms",
        "//command_line_option:platforms",
        "@aspect_rules_py//py/private/interpreter:freethreaded",
        "@aspect_rules_py//py:python_version",
        "@aspect_rules_py//uv/private/constraints/platform:platform_libc",
    ],
)

def _configured_toolchain_checks_impl(ctx):
    return [DefaultInfo(files = depset(
        transitive = [target[DefaultInfo].files for target in ctx.attr.checks],
    ))]

_configured_toolchain_checks = rule(
    implementation = _configured_toolchain_checks_impl,
    attrs = {
        "checks": attr.label_list(cfg = _toolchain_test_transition, mandatory = True),
        "execution_platform": attr.label(mandatory = True),
        "freethreaded": attr.bool(),
        "interpreter_setting": attr.string(),
        "interpreter_setting_secondary": attr.string(),
        "libc": attr.string(mandatory = True),
        "python_version": attr.string(mandatory = True),
        "target_platform": attr.label(mandatory = True),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)

def toolchain_resolution_test(
        name,
        checks,
        execution_platform,
        python_version,
        target_platform,
        libc = "glibc",
        freethreaded = False,
        interpreter_setting = "",
        interpreter_setting_secondary = ""):
    """Tests toolchain resolution under an explicit target/exec configuration."""
    configured_checks = name + "_configured"
    _configured_toolchain_checks(
        name = configured_checks,
        checks = checks,
        execution_platform = execution_platform,
        freethreaded = freethreaded,
        interpreter_setting = interpreter_setting,
        interpreter_setting_secondary = interpreter_setting_secondary,
        libc = libc,
        python_version = python_version,
        tags = ["manual"],
        target_platform = target_platform,
    )
    build_test(
        name = name,
        tags = ["manual"],
        targets = [configured_checks],
    )
