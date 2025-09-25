load("@bazel_skylib//lib:selects.bzl", "selects")
load("//pip/private/constraints:defs.bzl", "MAJORS", "MINORS", "PATCHES", "INTERPRETERS", "FLAGS")

def generate():
    for interpreter in INTERPRETERS:
        for major in MAJORS:

            selects.config_setting_group(
                name = "{}{}".format(interpreter, major),
                match_all = [
                    "//pip/private/constraints/python/major:{}".format(major),
                ]
            )
            
            for minor in MINORS:
                
                selects.config_setting_group(
                    name = "{}{}{}".format(interpreter, major, minor),
                    match_all = [
                        "//pip/private/constraints/python/major:{}".format(major),
                        "//pip/private/constraints/python/minor:{}".format(minor),
                    ]
                )
