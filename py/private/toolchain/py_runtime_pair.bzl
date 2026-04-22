"""Custom py_runtime_pair rule that emits a ToolchainInfo consumable by rules_py.

This replaces @rules_python//python:py_runtime_pair to remove the dependency
on rules_python runtime rules.
"""

load(":py_runtime.bzl", "AspectPyRuntimeInfo")

def _aspect_py_runtime_pair_impl(ctx):
    py2_runtime = None
    if ctx.attr.py2_runtime:
        py2_runtime = ctx.attr.py2_runtime[AspectPyRuntimeInfo]

    py3_runtime = ctx.attr.py3_runtime[AspectPyRuntimeInfo]

    return [
        DefaultInfo(
            files = depset(
                transitive = [
                    ctx.attr.py3_runtime[DefaultInfo].files,
                ] + ([ctx.attr.py2_runtime[DefaultInfo].files] if ctx.attr.py2_runtime else []),
            ),
        ),
        platform_common.ToolchainInfo(
            py2_runtime = py2_runtime,
            py3_runtime = py3_runtime,
        ),
    ]

aspect_py_runtime_pair = rule(
    implementation = _aspect_py_runtime_pair_impl,
    doc = """Declares a Python runtime pair for use with rules_py toolchains.

This is a drop-in replacement for rules_python's py_runtime_pair that consumes
AspectPyRuntimeInfo and emits a compatible ToolchainInfo.
""",
    attrs = {
        "py2_runtime": attr.label(
            doc = "The PY2 runtime. May be None.",
            providers = [AspectPyRuntimeInfo],
        ),
        "py3_runtime": attr.label(
            doc = "The PY3 runtime. Mandatory.",
            providers = [AspectPyRuntimeInfo],
            mandatory = True,
        ),
    },
    provides = [platform_common.ToolchainInfo],
)
