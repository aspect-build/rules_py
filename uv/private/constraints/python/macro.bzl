"""
Generate a version cascade on Python interpreters.
"""

load("//uv/private/constraints:defs.bzl", "INTERPRETERS", "MAJORS", "MINORS")
load(":defs.bzl", "is_python_version_at_least")

# buildifier: disable=unnamed-macro
# buildifier: disable=function-docstring
def generate(
        visibility):
    for major in MAJORS:
        is_python_version_at_least(
            name = "py{}".format(major),
            version = "{}.0".format(major),
            visibility = visibility,
        )

        for minor in MINORS:
            is_python_version_at_least(
                name = "py{}{}".format(major, minor),
                version = "{}.{}".format(major, minor),
                visibility = visibility,
            )

    # The settings check only the interpreter version, so every non-generic
    # tag (cp312, ...) evaluates identically to its py equivalent.
    for interpreter in INTERPRETERS:
        if interpreter == "py":
            continue
        for major in MAJORS:
            native.alias(
                name = "{}{}".format(interpreter, major),
                actual = ":py{}".format(major),
                visibility = visibility,
            )

            for minor in MINORS:
                native.alias(
                    name = "{}{}{}".format(interpreter, major, minor),
                    actual = ":py{}{}".format(major, minor),
                    visibility = visibility,
                )
