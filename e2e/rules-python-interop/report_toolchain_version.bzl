"""Runnables that print the resolved toolchain's Python version and repo.

Each resolves its toolchain directly (no py_* version transition), so the
reported version reflects the version flag only if the flag is authoritative in
the interpreter hub. The repo name says which ruleset provisioned the
interpreter, so a version both rulesets can serve can't mask a broken fallback.
`bazel run` it and assert on stdout.
"""

_RUNTIME_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"
_EXEC_TOOLS_TOOLCHAIN = "@aspect_rules_py//py/private/toolchain:exec_tools_toolchain_type"

def _report_impl(ctx):
    runtime = getattr(ctx.toolchains[ctx.attr._toolchain_type], ctx.attr._runtime_field)
    version_info = runtime.interpreter_version_info
    launcher = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = launcher,
        content = "#!/usr/bin/env bash\necho '{}.{} {}'\n".format(
            version_info.major,
            version_info.minor,
            runtime.interpreter.owner.repo_name,
        ),
        is_executable = True,
    )
    return [DefaultInfo(executable = launcher)]

def _report_rule(toolchain_type, runtime_field):
    return rule(
        implementation = _report_impl,
        attrs = {
            "_runtime_field": attr.string(default = runtime_field),
            "_toolchain_type": attr.string(default = toolchain_type),
        },
        toolchains = [toolchain_type],
        executable = True,
    )

report_version = _report_rule(_RUNTIME_TOOLCHAIN, "py3_runtime")
report_exec_version = _report_rule(_EXEC_TOOLS_TOOLCHAIN, "exec_runtime")
