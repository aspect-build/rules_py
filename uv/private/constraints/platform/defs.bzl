"""
Helpers & constants.
"""

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

    return (
        platform_tag == "any" or
        platform_tag.startswith("macosx_") or
        platform_tag.startswith("manylinux_") or
        platform_tag.startswith("musllinux_") or
        platform_tag.startswith("win")
    )


# Adapted from rules_python's config_settings.bzl
_PYTHON_VERSION_FLAG = Label("@rules_python//python/config_settings:python_version")
_PYTHON_VERSION_MAJOR_MINOR_FLAG = Label("@rules_python//python/config_settings:python_version_major_minor")

def is_platform_version_at_least(name, version = None, visibility = visibility, **kwargs):
    version = version or name
    flag_name = "_{}_flag".format(name)
    native.config_setting(
        name = name,
        flag_values = {
            flag_name: "yes",
        },
        visibility = visibility,
    )
    _platform_version_at_least(
        name = flag_name,
        at_least = version,
        visibility = ["//visibility:private"],
        **kwargs
    )

def _platform_version_at_least_impl(ctx):
    flag_value = ctx.attr._major_minor[config_common.FeatureFlagInfo].value

    # CI is, somehow, getting an empty string for the current flag value.
    # How isn't clear.
    if not flag_value:
        return [config_common.FeatureFlagInfo(value = "no")]

    current = tuple([
        int(x)
        for x in flag_value.split(".")
    ])
    at_least = tuple([int(x) for x in ctx.attr.at_least.split(".")])

    value = "yes" if current >= at_least else "no"
    return [config_common.FeatureFlagInfo(value = value)]

_python_version_at_least = rule(
    implementation = _python_version_at_least_impl,
    attrs = {
        "at_least": attr.string(mandatory = True),
        "major_minor": attr.label(default = _PYTHON_VERSION_MAJOR_MINOR_FLAG),
    },
)
