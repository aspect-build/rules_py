"""Checks that a final-release-only dependency is absent on a prerelease."""

load("@aspect_rules_py//py:defs.bzl", "PyInfo")

def _marker_dependency_check_impl(ctx):
    if ctx.attr.dep[PyInfo].transitive_sources.to_list():
        fail("{} was selected for a Python prerelease".format(ctx.attr.dep.label))
    return []

marker_dependency_check = rule(
    implementation = _marker_dependency_check_impl,
    attrs = {"dep": attr.label(mandatory = True, providers = [PyInfo])},
)
