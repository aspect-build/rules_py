"""
"""

load("//pip/private/constraints:defs.bzl", "MAJORS", "generate_gte_ladder")

# buildifier: disable=unnamed-macro
# buildifier: disable=function-docstring
def generate():
    native.constraint_setting(
        name = "major",
        default_constraint_value = "is_3",
    )
    stages = []
    for major in MAJORS:
        name = "is_{}".format(major)
        native.constraint_value(
            name = name,
            constraint_setting = ":major",
        )
        stages.append(struct(name = name[3:], condition = name))

    generate_gte_ladder(stages)
