"""Runnable that prints the resolved Python runtime toolchain's version.

Resolves the runtime toolchain directly (no py_* version transition), so the
reported version reflects the version flag only if the flag is authoritative
in the interpreter hub. `bazel run` it and assert on stdout.
"""

_RUNTIME_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"

def _report_version_impl(ctx):
    version_info = ctx.toolchains[_RUNTIME_TOOLCHAIN].py3_runtime.interpreter_version_info
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

report_version = rule(
    implementation = _report_version_impl,
    toolchains = [_RUNTIME_TOOLCHAIN],
    executable = True,
)
