"""
Generate interpreter ABI config_settings for wheel selection.

Each ABI tag from a wheel filename (e.g. cp312, cp312t, cp312dmu) maps to a
config_setting whose flag_values AND a Python version check with interpreter
feature flag checks. The feature flags are backed by bool_flags defined in
//py/private/interpreter:BUILD.bazel and are set by the interpreter toolchain
provisioning system.
"""

load("@bazel_skylib//lib:selects.bzl", "selects")
load("//uv/private/constraints:defs.bzl", "INTERPRETERS", "MAJORS", "MINORS")

# Canonical locations of the interpreter feature flags.
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

    native.alias(
        name = "abi3",
        actual = "//uv/private/constraints/python:py33",
        visibility = visibility,
    )

    # A native config_setting ANDs all of its flag_values entries, so each
    # abi tag is one target instead of a config_setting_group chain — this
    # loop emits 1344 tags, so the per-tag target count matters.
    for interpreter in INTERPRETERS:
        for major in MAJORS:
            for minor in MINORS:
                version_flag = "//uv/private/constraints/python:_py{}{}_flag".format(major, minor)
                for d in [False, True]:
                    for m in [False, True]:
                        for t in [False, True]:
                            for u in [False, True]:
                                native.config_setting(
                                    name = "{0}{1}{2}{3}{4}{5}{6}".format(
                                        interpreter,
                                        major,
                                        minor,
                                        "d" if d else "",
                                        "m" if m else "",
                                        "t" if t else "",
                                        "u" if u else "",
                                    ),
                                    flag_values = {
                                        version_flag: "yes",
                                        _PYDEBUG_FLAG: "true" if d else "false",
                                        _PYMALLOC_FLAG: "true" if m else "false",
                                        _FREETHREADING_FLAG: "true" if t else "false",
                                        _WIDE_UNICODE_FLAG: "true" if u else "false",
                                    },
                                    visibility = visibility,
                                )
