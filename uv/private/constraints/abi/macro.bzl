"""
Generate interpreter ABI config_settings for wheel selection.

Each ABI tag from a wheel filename (e.g. cp312, cp312t, cp312dmu) maps to a
config_setting_group that combines a Python version check with interpreter
feature flag checks. The feature flags are derived from the repeatable
--interpreter_feature flag defined in //py/private/interpreter:BUILD.bazel.
"""

load("@bazel_skylib//lib:selects.bzl", "selects")
load("//uv/private/constraints:defs.bzl", "INTERPRETERS", "MAJORS", "MINORS")

# Canonical locations of the derived interpreter feature flags.
# These are interpreter_has_feature rules that expose FeatureFlagInfo.
_PYDEBUG_FLAG = "//py/private/interpreter:pydebug"
_PYMALLOC_FLAG = "//py/private/interpreter:pymalloc"
_FREETHREADING_FLAG = "//py/private/interpreter:freethreaded"
_WIDE_UNICODE_FLAG = "//py/private/interpreter:wide_unicode"

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

    # Interpreter feature flag config_settings. Each pair (enabled/disabled)
    # checks the corresponding derived flag from //py/private/interpreter.
    native.config_setting(
        name = "pydebug_enabled",
        flag_values = {_PYDEBUG_FLAG: "true"},
        visibility = visibility,
    )
    native.config_setting(
        name = "pydebug_disabled",
        flag_values = {_PYDEBUG_FLAG: "false"},
        visibility = visibility,
    )

    native.config_setting(
        name = "pymalloc_enabled",
        flag_values = {_PYMALLOC_FLAG: "true"},
        visibility = visibility,
    )
    native.config_setting(
        name = "pymalloc_disabled",
        flag_values = {_PYMALLOC_FLAG: "false"},
        visibility = visibility,
    )

    native.config_setting(
        name = "freethreading_enabled",
        flag_values = {_FREETHREADING_FLAG: "true"},
        visibility = visibility,
    )
    native.config_setting(
        name = "freethreading_disabled",
        flag_values = {_FREETHREADING_FLAG: "false"},
        visibility = visibility,
    )

    native.config_setting(
        name = "wide_unicode_enabled",
        flag_values = {_WIDE_UNICODE_FLAG: "true"},
        visibility = visibility,
    )
    native.config_setting(
        name = "wide_unicode_disabled",
        flag_values = {_WIDE_UNICODE_FLAG: "false"},
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
                        "//uv/private/constraints/python:py{}{}".format(major, minor),
                    ],
                    visibility = visibility,
                )

                for d in [False, True]:
                    for m in [False, True]:
                        for t in [False, True]:
                            for u in [False, True]:
                                selects.config_setting_group(
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
                                        ([":pydebug_enabled"] if d else [":pydebug_disabled"]) +
                                        ([":pymalloc_enabled"] if m else [":pymalloc_disabled"]) +
                                        ([":freethreading_enabled"] if t else [":freethreading_disabled"]) +
                                        ([":wide_unicode_enabled"] if u else [":wide_unicode_disabled"])
                                    ),
                                    visibility = visibility,
                                )
