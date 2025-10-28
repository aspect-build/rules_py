"""
Generate a version cascade on Python interpreters.
"""

load("//uv/private/constraints:defs.bzl", "INTERPRETERS", "MAJORS", "MINORS")
load(":defs.bzl", "is_python_version_at_least")

# buildifier: disable=unnamed-macro
# buildifier: disable=function-docstring
def generate(
        visibility):
    # FIXME: Needs to generate a cascade.
    for interpreter in INTERPRETERS:
        for major in MAJORS:
            is_python_version_at_least(
                name = "{}{}".format(interpreter, major),
                version = "{}.0".format(major),
                visibility = visibility,
            )

            for minor in MINORS:
                is_python_version_at_least(
                    name = "{}{}{}".format(interpreter, major, minor),
                    version = "{}.{}".format(major, minor),
                    visibility = visibility,
                )
