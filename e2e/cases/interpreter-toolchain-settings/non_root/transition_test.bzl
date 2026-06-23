"""Transition assertion used by standalone interpreter-extension fixtures."""

load("@aspect_rules_py//py/private:transitions.bzl", "python_transition")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

_VersionValuesInfo = provider(fields = ["aspect", "rules_python"])

def _version_probe_impl(ctx):
    return [_VersionValuesInfo(
        aspect = ctx.attr._aspect[BuildSettingInfo].value,
        rules_python = ctx.attr._rules_python[BuildSettingInfo].value,
    )]

_version_probe = rule(
    implementation = _version_probe_impl,
    attrs = {
        "_aspect": attr.label(default = "@python_interpreters//:python_version"),
        "_rules_python": attr.label(default = "@rules_python//python/config_settings:python_version"),
    },
)

def _version_transition_check_impl(ctx):
    if len(ctx.attr.probe) != 1:
        fail("expected one transitioned version probe, got {}".format(len(ctx.attr.probe)))
    values = ctx.attr.probe[0][_VersionValuesInfo]
    if values.aspect != ctx.attr.expected or values.rules_python != ctx.attr.expected:
        fail(
            "expected both transitioned flags to be {}, got Aspect {} and rules_python {}".format(
                ctx.attr.expected,
                values.aspect,
                values.rules_python,
            ),
        )
    return []

_version_transition_check = rule(
    implementation = _version_transition_check_impl,
    attrs = {
        "expected": attr.string(mandatory = True),
        "probe": attr.label(cfg = python_transition, mandatory = True),
        "python_version": attr.string(),
    },
)

def version_transition_check(name, expected):
    probe_name = name + "_probe"
    _version_probe(name = probe_name)
    _version_transition_check(
        name = name,
        expected = expected,
        probe = probe_name,
    )
