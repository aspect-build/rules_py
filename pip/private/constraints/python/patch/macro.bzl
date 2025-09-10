load("@bazel_skylib//lib:selects.bzl", "selects")
load("//pip/private/constraints:defs.bzl", "MAJORS", "MINORS", "PATCHES", "INTERPRETERS", "FLAGS")


def generate():
    native.constraint_setting(
        name = "patch",
    )
    for patch in PATCHES:
        native.constraint_value(
            name = str(patch),
            constraint_setting = ":patch",
        )
