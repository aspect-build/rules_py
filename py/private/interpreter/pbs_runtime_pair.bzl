"""Attach CPython bytecode identity to a PBS runtime pair.

The returned ToolchainInfo extends rules_python's public runtime-pair schema
with `pyc_magic_number`, CPython's 16-bit PYC_MAGIC_NUMBER value:
https://github.com/bazel-contrib/rules_python/blob/1.9.0/python/py_runtime_pair.bzl#L31-L41
"""

load("@rules_python//python:py_runtime_info.bzl", "PyRuntimeInfo")

def _pbs_runtime_pair_impl(ctx):
    runtime = ctx.attr.py3_runtime[PyRuntimeInfo]
    if runtime.python_version != "PY3":
        fail("pbs_runtime_pair requires a Python 3 runtime")
    return [platform_common.ToolchainInfo(
        py2_runtime = None,
        py3_runtime = runtime,
        pyc_magic_number = ctx.attr.pyc_magic_number,
    )]

pbs_runtime_pair = rule(
    implementation = _pbs_runtime_pair_impl,
    attrs = {
        "pyc_magic_number": attr.int(mandatory = True),
        "py3_runtime": attr.label(
            cfg = "target",
            mandatory = True,
            providers = [PyRuntimeInfo],
        ),
    },
)
