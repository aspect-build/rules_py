"""Materialises the resolved exec-tools toolchain payload for assertion.

Reads the fields rules_python's consumers access — `exec_tools.exec_runtime`
and `exec_tools.precompiler` — so the test pins that rules_py's registration
under rules_python's toolchain type keeps their expected shape.
"""

EXEC_TOOLS_TOOLCHAIN = "@rules_python//python:exec_tools_toolchain_type"

def _exec_tools_facts_impl(ctx):
    exec_tools = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN].exec_tools
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "{}\n{}\n".format(
        exec_tools.exec_runtime.interpreter.path,
        exec_tools.precompiler,
    ))
    return [DefaultInfo(files = depset([out]))]

exec_tools_facts = rule(
    implementation = _exec_tools_facts_impl,
    toolchains = [EXEC_TOOLS_TOOLCHAIN],
)

def _set_python_version_impl(settings, attr):
    # Both flags together so the uv constraints mismatch guard stays satisfied.
    return {
        "@aspect_rules_py//py/private/interpreter:python_version": attr.python_version,
        "@rules_python//python/config_settings:python_version": attr.python_version,
    }

_set_python_version = transition(
    implementation = _set_python_version_impl,
    inputs = [],
    outputs = [
        "@aspect_rules_py//py/private/interpreter:python_version",
        "@rules_python//python/config_settings:python_version",
    ],
)

def _with_python_version_impl(ctx):
    return [DefaultInfo(files = depset(transitive = [
        dep[DefaultInfo].files
        for dep in ctx.attr.deps
    ]))]

with_python_version = rule(
    doc = """Forwards deps analyzed under an explicit Python version.

py_* data edges reset the Python flags to the caller baseline (#1294), so a
data file that must be produced under a specific version pins it here rather
than inheriting the consuming terminal's transition.""",
    implementation = _with_python_version_impl,
    attrs = {
        "deps": attr.label_list(mandatory = True),
        "python_version": attr.string(mandatory = True),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    cfg = _set_python_version,
)
