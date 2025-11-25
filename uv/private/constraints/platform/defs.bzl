"""
Helpers & constants.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

def supported_platform(platform_tag):
    """Predicate.

    Indicate whether the current `pip` implementation supports the platform
    represented by a given wheel platform tag. Allows for filtering out of
    wheels for currently unsupported platforms, being:

    - Android
    - iOS
    - The legacy/undefined linux_* platforms

    Args:
        platform_tag (str): A wheel platform tag

    Returns:
        bool; whether the platform is supported or not.

    """
    # We currently don't support:
    # - `linux_*` which doesn't seem standardized
    # - `android_` which could be supported but we don't have to
    # - `ios_*` which could be supported but we don't have to
    # - Windows

    return (
        platform_tag == "any" or
        platform_tag.startswith("macosx_") or
        platform_tag.startswith("manylinux_") or
        platform_tag.startswith("musllinux_")
    )

# Adapted from rules_python's config_settings.bzl
MAJOR_MINOR_FLAG = Label("//uv/private/constraints/platform:platform_version")

def _platform_version_at_least_impl(ctx):
    flag_value = ctx.attr._major_minor[BuildSettingInfo].value

    current = tuple([
        int(x)
        for x in flag_value.split(".")
    ])
    at_least = tuple([int(x) for x in ctx.attr.at_least.split(".")])

    value = "true" if current >= at_least else "false"
    return [config_common.FeatureFlagInfo(value = value)]

platform_version_at_least = rule(
    implementation = _platform_version_at_least_impl,
    attrs = {
        "at_least": attr.string(mandatory = True),
        "_major_minor": attr.label(default = MAJOR_MINOR_FLAG),
    },
)
