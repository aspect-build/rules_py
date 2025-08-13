"""
Generate a version cascade on Python interpreters.
"""

load("@bazel_skylib//lib:selects.bzl", "selects")
load("//uv/private/constraints:defs.bzl", "INTERPRETERS", "MAJORS", "MINORS")

# buildifier: disable=unnamed-macro
# buildifier: disable=function-docstring
def generate():
    # FIXME: Needs to generate a cascade.
    for interpreter in INTERPRETERS:
        for major in MAJORS:
            selects.config_setting_group(
                name = "{}{}".format(interpreter, major),
                match_all = [
                    "//uv/private/constraints/python/major:{}".format(major),
                ],
            )

            for minor in MINORS:
                selects.config_setting_group(
                    name = "{}{}{}".format(interpreter, major, minor),
                    match_all = [
                        "//uv/private/constraints/python/major:{}".format(major),
                        "//uv/private/constraints/python/minor:{}".format(minor),
                    ],
                )
