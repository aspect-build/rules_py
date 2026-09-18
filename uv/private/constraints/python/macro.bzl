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

    # Generic Python tags are lower bounds, while implementation-specific
    # minor tags only match that interpreter minor.
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
                version_flag = ":_py{}{}_flag".format(major, minor)
                version_flags = {version_flag: "yes"}
                if minor + 1 in MINORS:
                    next_version_flag = ":_py{}{}_flag".format(major, minor + 1)
                    version_flags[next_version_flag] = "no"
                native.config_setting(
                    name = "{}{}{}".format(interpreter, major, minor),
                    flag_values = version_flags,
                    visibility = visibility,
                )
