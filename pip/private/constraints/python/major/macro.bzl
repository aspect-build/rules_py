load("@bazel_skylib//lib:selects.bzl", "selects")
load("//pip/private/constraints:defs.bzl", "MAJORS", "MINORS", "INTERPRETERS", "FLAGS")

def generate():
    native.constraint_setting(
        name = "major",
    )
    for major in MAJORS:
        native.constraint_value(
            name = str(major),
            constraint_setting = ":major",
        )
