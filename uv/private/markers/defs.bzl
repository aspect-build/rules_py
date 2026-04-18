"""Integration between PEP-508 marker evaluation and Bazel select()s.

This module exposes a rule and a macro that translate a PEP-508 marker
expression (e.g. `sys_platform == "linux"`) into a Bazel `config_setting`
that can drive `select()` statements.  The flow is:

1. `decide_marker` creates a private rule that evaluates the marker against
   the current build configuration.
2. That rule emits `FeatureFlagInfo` with value `"true"` or `"false"`.
3. A public `config_setting` is generated that matches `"true"`.
4. Downstream targets use `select({":my_marker": real_dep, ...})`.

This allows Python conditional dependencies to be resolved at Bazel
configuration time rather than statically at repository time.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(":pep508_evaluate.bzl", _evaluate_marker = "evaluate")

def _decide_marker_impl(ctx):
    """Evaluate a PEP-508 marker and emit a FeatureFlagInfo.

    The environment used for evaluation is built from configurable build
    settings such as `python_version`, `os_name`, `sys_platform`, etc.
    Both `FeatureFlagInfo` and `BuildSettingInfo` providers are supported
    as sources for those settings.

    Args:
      ctx: the rule context.

    Returns:
      A list containing a single `FeatureFlagInfo` provider whose value is
      `"true"` when the marker matches and `"false"` otherwise.
    """
    FeatureFlagInfo = config_common.FeatureFlagInfo

    extras = sorted(ctx.attr.extras)
    extra = ",".join(extras)
    dependency_groups = sorted(ctx.attr.dependency_groups)

    def _value(it):
        """Dereference a target that provides FeatureFlagInfo or BuildSettingInfo."""
        if FeatureFlagInfo in it:
            return it[FeatureFlagInfo].value
        elif BuildSettingInfo in it:
            return it[BuildSettingInfo].value
        else:
            fail("Unable to deref %r" % it)

    res = _evaluate_marker(
        marker = ctx.attr.marker,
        env = {
            # FIXME: technically these three aren't always defined per the spec,
            # but this implementation always has them present.
            # https://packaging.python.org/en/latest/specifications/dependency-specifiers/#environment-markers
            "extra": extra,
            "extras": extras,
            "dependency_groups": dependency_groups,
            "python_version": _value(ctx.attr.python_version),
            "python_full_version": _value(ctx.attr.python_full_version),
            "os_name": _value(ctx.attr.os_name),
            "sys_platform": _value(ctx.attr.sys_platform),
            "os_release": _value(ctx.attr.os_release),
            "platform_machine": _value(ctx.attr.platform_machine),
            "platform_system": _value(ctx.attr.platform_system),
            "platform_version": _value(ctx.attr.platform_version),
            "platform_python_implementation": _value(ctx.attr.platform_python_implementation),
            "implementation_name": _value(ctx.attr.implementation_name),
            "implementation_version": _value(ctx.attr.implementation_version),
        },
    )

    return [
        config_common.FeatureFlagInfo(value = "true" if res else "false"),
    ]

_decide_marker = rule(
    implementation = _decide_marker_impl,
    attrs = {
        "marker": attr.string(),
        "extras": attr.string_list(default = []),
        "dependency_groups": attr.string_list(default = []),
        "python_version": attr.label(default = Label(":python_version")),
        "python_full_version": attr.label(default = Label(":python_full_version")),
        "os_name": attr.label(default = Label(":os_name")),
        "sys_platform": attr.label(default = Label(":sys_platform")),
        "os_release": attr.label(default = Label(":os_release")),
        "platform_system": attr.label(default = Label(":platform_system")),
        "platform_version": attr.label(default = Label(":platform_version")),
        "platform_machine": attr.label(default = Label(":platform_machine")),
        "platform_python_implementation": attr.label(default = Label(":platform_python_implementation")),
        "implementation_name": attr.label(default = Label(":implementation_name")),
        "implementation_version": attr.label(default = Label(":implementation_version")),
    },
)

def decide_marker(
        name,
        marker,
        extras = [],
        dependency_groups = [],
        visibility = None,
        **kwargs):
    """Create a config_setting driven by a PEP-508 marker evaluation.

    Generates two targets:
      * `_{name}_impl` (private) – the actual marker decider rule.
      * `{name}` (public) – a `config_setting` that matches when the
        decider outputs `"true"`.

    Args:
      name:              name for the public config_setting.
      marker:            the PEP-508 marker string to evaluate.
      extras:            list of extra names to expose as `extra` / `extras`.
      dependency_groups: list of dependency group names.
      visibility:        visibility for the config_setting.
      **kwargs:          forwarded to the underlying `_decide_marker` rule.
    """
    flag_name = "_{}_impl".format(name)
    native.config_setting(
        name = name,
        flag_values = {
            flag_name: "true",
        },
        visibility = visibility,
    )
    _decide_marker(
        name = flag_name,
        marker = marker,
        extras = extras,
        dependency_groups = dependency_groups,
        visibility = ["//visibility:private"],
        **kwargs
    )

def _configurable_string_impl(ctx):
    """Rule implementation that forwards an attr.string to FeatureFlagInfo."""
    return [
        config_common.FeatureFlagInfo(value = ctx.attr.value),
    ]

configurable_string = rule(
    implementation = _configurable_string_impl,
    doc = "A simple rule that exposes a string value as FeatureFlagInfo.",
    attrs = {
        "value": attr.string(),
    },
)
