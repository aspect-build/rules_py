"""
Generate interpreter ABI config_settings for wheel selection.

Each ABI tag from a wheel filename (e.g. cp312, cp312t, cp312dmu) maps to a
config_setting_group that combines a Python version check with interpreter
feature flag checks. The feature flags are backed by bool_flags defined in
//py/private/interpreter:BUILD.bazel and are set by the interpreter toolchain
provisioning system.

The set of generated targets is derived from the same data as the
supported_abi() allowlist in defs.bzl; see the note there.
"""

load("@bazel_skylib//lib:selects.bzl", "selects")
load("//uv/private/constraints:defs.bzl", "INTERPRETERS", "MAJORS", "MINORS")
load(":defs.bzl", "ABI_FEATURES", "ABI_FEATURE_SUFFIXES")

# Canonical locations of the interpreter feature flags, keyed by the
# config_setting name prefix used in ABI_FEATURES.
_FEATURE_FLAGS = {
    "pydebug": "//py/private/interpreter:pydebug",
    "pymalloc": "//py/private/interpreter:pymalloc",
    "freethreading": "//py/private/interpreter:freethreaded",
    "wide_unicode": "//py/private/interpreter:wide_unicode",
}

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
    # checks the corresponding bool_flag from //py/private/interpreter.
    for feature_name, flag in _FEATURE_FLAGS.items():
        native.config_setting(
            name = "{}_enabled".format(feature_name),
            flag_values = {flag: "true"},
            visibility = visibility,
        )
        native.config_setting(
            name = "{}_disabled".format(feature_name),
            flag_values = {flag: "false"},
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

                for suffix in ABI_FEATURE_SUFFIXES:
                    selects.config_setting_group(
                        name = "{}{}{}{}".format(interpreter, major, minor, suffix),
                        match_all = [
                            ":is_{}{}{}".format(interpreter, major, minor),
                        ] + [
                            ":{}_{}".format(feature_name, "enabled" if letter in suffix else "disabled")
                            for letter, feature_name in ABI_FEATURES.items()
                        ],
                        visibility = visibility,
                    )
