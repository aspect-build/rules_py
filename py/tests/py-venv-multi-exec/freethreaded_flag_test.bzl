"""Runs a test binary under the freethreaded flag via a plain flag transition.

Not a platform with `flags`: Bazel 9 reapplies platform-based flags after
every transition, which would reassert freethreaded=true over the venv's
own override and defeat the scenario under test.
"""

_FREETHREADED_FLAG = "//py/private/interpreter:freethreaded"

def _freethreaded_flag_impl(_settings, _attr):
    return {_FREETHREADED_FLAG: True}

_freethreaded_flag_transition = transition(
    implementation = _freethreaded_flag_impl,
    inputs = [],
    outputs = [_FREETHREADED_FLAG],
)

def _freethreaded_flag_test_impl(ctx):
    binary = ctx.attr.binary[0]
    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(
        output = executable,
        target_file = binary[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )
    providers = [DefaultInfo(
        executable = executable,
        runfiles = binary[DefaultInfo].default_runfiles,
    )]
    if RunEnvironmentInfo in binary:
        providers.append(binary[RunEnvironmentInfo])
    return providers

freethreaded_flag_test = rule(
    implementation = _freethreaded_flag_test_impl,
    test = True,
    attrs = {
        "binary": attr.label(
            cfg = _freethreaded_flag_transition,
            executable = True,
            mandatory = True,
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)
