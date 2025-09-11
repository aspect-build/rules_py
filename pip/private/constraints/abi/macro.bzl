load("@bazel_skylib//lib:selects.bzl", "selects")
load("//pip/private/constraints:defs.bzl", "MAJORS", "MINORS", "INTERPRETERS", "FLAGS")

# FIXME: Where does abi 2/3/4 fit in here?
# FIXME: Where do ABI feature flags fit in here?
def generate():
    """
    Lay down `py3`, `py312`, `cp3`, `cp312` etc and critically `any`.

    The interpretation is a bit tricky because `cp`
    """

    # FIXME: Is there a better/worse way to do this?
    native.alias(
        name = "any",
        actual = "//conditions:default",
    )

    for interpreter in INTERPRETERS:
        for major in MAJORS:
            selects.config_setting_group(
                name = "{}{}".format(interpreter, major),
                match_all = [
                    "//pip/private/constraints/python/interpreter:{}".format(interpreter),
                    "//pip/private/constraints/python/major:{}".format(major),
                ]
            )

            for minor in MINORS:
                selects.config_setting_group(
                    name = "{}{}{}".format(interpreter, major, minor),
                    match_all = [
                        "//pip/private/constraints/python/interpreter:{}".format(interpreter),
                        "//pip/private/constraints/python/major:{}".format(major),
                        "//pip/private/constraints/python/minor:{}".format(minor),
                    ]
                )

                # FIXME: Create the abi feature flags?
