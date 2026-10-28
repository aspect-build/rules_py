"""Analysis assertions for target and exec configuration propagation."""

# buildifier: disable=bzl-visibility
load("@aspect_rules_py//py/private:transitions.bzl", "python_transition")

VersionInfo = provider("Observed version propagation through the fixture graph.", fields = ["value", "native", "tool"])

def _probe_impl(ctx):
    return [VersionInfo(
        value = ctx.attr.value,
        native = [dep[VersionInfo].value for dep in ctx.attr.deps],
        tool = ctx.attr.tool[VersionInfo].value if ctx.attr.tool else None,
    )]

probe = rule(implementation = _probe_impl, attrs = {
    "value": attr.string(),
    "deps": attr.label_list(),
    "tool": attr.label(cfg = "exec"),
})

def _check_impl(ctx):
    info = ctx.attr.target[0][VersionInfo]
    expected_native = ctx.attr.python_version if ctx.attr.native_version == "inherit" else ctx.attr.native_version

    # Outside project scope, whether exec tools keep the version depends on the
    # Bazel version (bazelbuild/bazel#26909), so only project mode asserts it.
    tool_ok = ctx.attr.native_version == "inherit" or info.tool == ctx.attr.python_version
    if info.value != ctx.attr.python_version or info.native != [expected_native] or not tool_ok:
        fail("Expected binding/tool %s, native %s; got %s" % (ctx.attr.python_version, expected_native, info))
    return [DefaultInfo()]

# Uses the terminals' transition, which also sets rules_python's flag and the
# internal baseline flags.
check = rule(implementation = _check_impl, attrs = {
    "target": attr.label(cfg = python_transition),
    "python_version": attr.string(),
    "native_version": attr.string(default = "inherit"),
    "_allowlist_function_transition": attr.label(default = "@bazel_tools//tools/allowlists/function_transition_allowlist"),
})
