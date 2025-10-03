load("//pip/private/constraints:defs.bzl", "PATCHES")

def generate():
    native.constraint_setting(
        name = "patch",
        default_constraint_value = "0",
    )
    for patch in PATCHES:
        native.constraint_value(
            name = str(patch),
            constraint_setting = ":patch",
        )
