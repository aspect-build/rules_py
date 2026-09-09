"""A wrapper forwarding a rules_py library's public providers, without PycInfo."""

load("//py/private:providers.bzl", "PyWheelsInfo")
load("//py/private:py_info.bzl", "PyInfo")

def _forward_providers_impl(ctx):
    actual = ctx.attr.actual
    return [actual[PyInfo], actual[PyWheelsInfo], actual[DefaultInfo]]

forward_providers = rule(
    implementation = _forward_providers_impl,
    attrs = {"actual": attr.label(providers = [PyInfo, PyWheelsInfo])},
)
