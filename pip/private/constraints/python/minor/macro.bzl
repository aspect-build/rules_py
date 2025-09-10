load("@bazel_skylib//lib:selects.bzl", "selects")
load("//pip/private/constraints:defs.bzl", "MAJORS", "MINORS", "INTERPRETERS", "FLAGS")


def generate():
    native.constraint_setting(
        name = "minor",
    )
    for minor in MINORS:
        native.constraint_value(
            name = str(minor),
            constraint_setting = ":minor",
        )
