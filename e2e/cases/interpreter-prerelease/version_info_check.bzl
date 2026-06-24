"""Checks the selected prerelease interpreter's declared version metadata."""

load("@aspect_rules_py//py/private:transitions.bzl", "python_version_transition")

_PY_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"
_EXPECTED = {
    "major": 3,
    "micro": 0,
    "minor": 15,
    "releaselevel": "alpha",
    "serial": 6,
}

def _version_info_check_impl(ctx):
    version_info = ctx.toolchains[_PY_TOOLCHAIN].py3_runtime.interpreter_version_info
    actual = {
        field: getattr(version_info, field, None)
        for field in _EXPECTED.keys()
    }
    if actual != _EXPECTED:
        fail("expected prerelease runtime metadata {}, got {}".format(_EXPECTED, actual))
    return [DefaultInfo()]

version_info_check = rule(
    implementation = _version_info_check_impl,
    attrs = {
        "python_version": attr.string(mandatory = True),
    },
    cfg = python_version_transition,
    toolchains = [_PY_TOOLCHAIN],
)
