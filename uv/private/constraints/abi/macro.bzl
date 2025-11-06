"""
Generate interpreter feature flag constraints

Or, as appropriate, aliases to the `rules_python` equivalents.
"""

load("@bazel_skylib//lib:selects.bzl", "selects")
load("//uv/private/constraints:defs.bzl", "INTERPRETERS", "MAJORS", "MINORS")

# buildifier: disable=unnamed-macro
# buildifier: disable=function-docstring
def generate(
        visibility):
    """
    Lay down `py3`, `py312`, `cp3`, `cp312` etc and critically `any`.

    The interpretation is a bit tricky because `cp`
    """

    # FIXME: Is there a better/worse way to do this?
    selects.config_setting_group(
        name = "none",
        match_all = [
            "//conditions:default",
        ],
    )

    # TODO: Replace all this with the rules_python feature flags
    # rules_python doesn't have _all_ of these
    #
    # There is //python/config_settings:py_freethreaded
    #
    # Likely better to offer our own Python toolchain flow which ties off with
    # our settings than to try and hang 1:1 off of rules_python's.
    native.constraint_setting(
        name = "feature_pydebug",
        default_constraint_value = ":pydebug_disabled",
        visibility = visibility,
    )
    native.constraint_value(
        name = "pydebug_enabled",
        constraint_setting = ":feature_pydebug",
        visibility = visibility,
    )
    native.constraint_value(
        name = "pydebug_disabled",
        constraint_setting = ":feature_pydebug",
        visibility = visibility,
    )

    native.constraint_setting(
        name = "feature_pymalloc",
        default_constraint_value = ":pymalloc_disabled",
        visibility = visibility,
    )
    native.constraint_value(
        name = "pymalloc_enabled",
        constraint_setting = ":feature_pymalloc",
        visibility = visibility,
    )
    native.constraint_value(
        name = "pymalloc_disabled",
        constraint_setting = ":feature_pymalloc",
        visibility = visibility,
    )

    native.constraint_setting(
        name = "feature_freethreading",
        default_constraint_value = ":freethreading_disabled",
        visibility = visibility,
    )
    native.constraint_value(
        name = "freethreading_enabled",
        constraint_setting = ":feature_freethreading",
        visibility = visibility,
    )
    native.constraint_value(
        name = "freethreading_disabled",
        constraint_setting = ":feature_freethreading",
        visibility = visibility,
    )

    native.constraint_setting(
        name = "feature_wide_unicode",
        default_constraint_value = ":wide_unicode_disabled",
        visibility = visibility,
    )
    native.constraint_value(
        name = "wide_unicode_enabled",
        constraint_setting = ":feature_wide_unicode",
        visibility = visibility,
    )
    native.constraint_value(
        name = "wide_unicode_disabled",
        constraint_setting = ":feature_wide_unicode",
        visibility = visibility,
    )

    native.alias(
        name = "abi3",
        actual = "is_py33",
        visibility = visibility,
    )

    for interpreter in INTERPRETERS:
        for major in MAJORS:
            for minor in MINORS:
                selects.config_setting_group(
                    name = "is_{}{}{}".format(interpreter, major, minor),
                    match_all = [
                        # "//uv/private/constraints/python/interpreter:{}".format(interpreter),
                        "//uv/private/constraints/python:py{}{}".format(major, minor),
                    ],
                    visibility = visibility,
                )

                for d in [False, True]:
                    for m in [False, True]:
                        for t in [False, True]:
                            for u in [False, True]:
                                selects.config_setting_group(
                                    # This is a bit out of hand I admit
                                    name = "{0}{1}{2}{3}{4}{5}{6}".format(
                                        interpreter,
                                        major,
                                        minor,
                                        "d" if d else "",
                                        "m" if m else "",
                                        "t" if t else "",
                                        "u" if u else "",
                                    ),
                                    match_all = (
                                        [
                                            ":is_{}{}{}".format(interpreter, major, minor),
                                        ] +
                                        ([":pydebug_enabled"] if d else []) +
                                        ([":pymalloc_enabled"] if m else []) +
                                        ([":freethreading_enabled"] if t else []) +
                                        ([":wide_unicode_enabled"] if u else [])
                                    ),
                                    visibility = visibility,
                                )
