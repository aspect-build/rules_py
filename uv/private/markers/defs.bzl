"""
An implementation of Python markers which can be used in select()s.

This implementation has three key pieces -- the marker evaluation logic (h/t
Ignas), a rule which allows us to dynamically decide the marker into a
BuildSettingInfo, and a macro which wraps that BuildSettingInfo rule with a
build condition allowing us to convert the pseudo-boolean rule output into a
selectable bit.

The flow looks like this
 - User specifies the build configuration
 - Macro select()s the build configuration into rule input values
 - Marker "decider" rule evaluates, producing a BuildSettingInfo of "true" or "false"
 - Wrapper flag value rule matches the output BuildSettingInfo to "true" and is True
 - select() rule(s) which decide on the wrapper flag rule triggers accordingly

Using marker expressions directly this way allows us to decide package
dependencies at configuration time rather than trying to decide them statically
at repository time.

Using individual dependency decisions equivalent to Python's defined packaging
semantics, we can translate a dependency such as

```
foo requires [
  bar; os_name == "nt"
]
```

into a few rules

```
# Null allows us to select() to "nothing" since dependencies can be inactive
py_library(
  name = "null",
  srcs = [],
  imports = []
)

decide_marker(
  name = "_bar_marker",
  marker = "os_name == \"nt\"",
)

alias(
  name = "_maybe_bar",
  actual = select({
    ":_bar_marker": "@bar_actual//lib",
    "//conditions:default": ":null",
  }),
)

py_library(
  name = "foo",
  deps = [
    ":_maybe_bar",
  ],
)
```

Thus the "foo" library will correctly depend on bar if and only if configuration
demands it.

"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(":pep508_evaluate.bzl", _evaluate_marker = "evaluate")

def _decide_marker_impl(ctx):
    """
    Decide the marker using PEP-508 logic
    """

    FeatureFlagInfo = config_common.FeatureFlagInfo

    extras = sorted(ctx.attr.extras)
    extra = ",".join(extras)
    dependency_groups = sorted(ctx.attr.dependency_groups)

    # Hide the differences between string flags and our custom build settings so
    # we can use them interchangeably.
    def _value(it):
        if FeatureFlagInfo in it:
            return it[FeatureFlagInfo].value
        elif BuildSettingInfo in it:
            return it[BuildSettingInfo].value
        else:
            fail("Unable to deref %r" % it)

    res = _evaluate_marker(
        marker = ctx.attr.marker,
        env = {
            # FIXME: Technically these aren't always defined... but this
            # implementation will have them present. [1]
            #
            # [1] https://packaging.python.org/en/latest/specifications/dependency-specifiers/#environment-markers
            #
            # {{{
            "extra": extra,
            "extras": extras,
            "dependency_groups": dependency_groups,
            # }}}
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

    # print(ctx.label, ctx.attr.marker, "->", res)

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
    return [
        config_common.FeatureFlagInfo(value = ctx.attr.value),
    ]

configurable_string = rule(
    implementation = _configurable_string_impl,
    attrs = {
        "value": attr.string(),
    },
)
