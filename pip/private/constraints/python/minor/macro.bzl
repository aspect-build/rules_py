load("//pip/private/constraints:defs.bzl", "MINORS", "generate_gte_ladder")

def generate():
    native.constraint_setting(
        name = "minor",
        default_constraint_value = "is_13",
    )
    stages = []
    for minor in MINORS:
        name = "is_{}".format(minor)
        native.constraint_value(
            name = name,
            constraint_setting = ":minor",
        )
        stages.append(struct(name = name[3:], condition = name))

    generate_gte_ladder(stages)
