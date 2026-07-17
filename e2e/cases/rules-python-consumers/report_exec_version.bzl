"""Runnable that prints the resolved exec-tools runtime version.

Resolves rules_py's exec-tools toolchain directly (no py_* version
transition), so the reported version reflects the version flag only if the flag
is authoritative in the interpreter hub. `bazel run` it and assert on stdout.
"""

_EXEC_TOOLS_TOOLCHAIN = "@aspect_rules_py//py/private/toolchain:exec_tools_toolchain_type"

def _report_exec_version_impl(ctx):
    version_info = ctx.toolchains[_EXEC_TOOLS_TOOLCHAIN].exec_runtime.interpreter_version_info
    launcher = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = launcher,
        content = "#!/usr/bin/env bash\necho '{}.{}'\n".format(
            version_info.major,
            version_info.minor,
        ),
        is_executable = True,
    )
    return [DefaultInfo(executable = launcher)]

report_exec_version = rule(
    implementation = _report_exec_version_impl,
    toolchains = [_EXEC_TOOLS_TOOLCHAIN],
    executable = True,
)
