"""Checks whether a lock-generated conditional Python dependency is active."""

load("@aspect_rules_py//py:defs.bzl", "PyInfo")

def _marker_dependency_check_impl(ctx):
    sources = ctx.attr.dep[PyInfo].transitive_sources.to_list()
    if bool(sources) != ctx.attr.present:
        fail("{} was {}selected by its uv marker".format(
            ctx.attr.dep.label,
            "not " if ctx.attr.present else "",
        ))
    return []

marker_dependency_check = rule(
    implementation = _marker_dependency_check_impl,
    attrs = {
        "dep": attr.label(mandatory = True, providers = [PyInfo]),
        "present": attr.bool(mandatory = True),
    },
)
