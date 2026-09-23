"""A srcs-less rule forwarding rules_python's PyInfo, like py_proto_library does."""

load("@rules_python//python:py_info.bzl", "PyInfo")

def _forward_py_info_impl(ctx):
    return [
        ctx.attr.actual[PyInfo],
        DefaultInfo(runfiles = ctx.attr.actual[DefaultInfo].default_runfiles),
    ]

forward_py_info = rule(
    implementation = _forward_py_info_impl,
    attrs = {"actual": attr.label(providers = [PyInfo])},
    provides = [PyInfo],
)
