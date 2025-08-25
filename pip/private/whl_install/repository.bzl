"""

Wheel installation repos are actually a bit tricky because this is where we go
from wheel files to a filegroup/py_library. That means we have to perform
platform wheel selection here as well as invoking the installation action to
produce a filegroup/TreeArtifact.

"""

load(":parse_whl_name.bzl", "parse_whl_name")


def _whl_install_impl(repository_ctx):
    print(repository_ctx.attr)

    prebuilds = json.decode(repository_ctx.attr.prebuilds)
    # Prebuilds is a mapping from whl file name to repo labels which contain
    # that file. We need to take these wheel files and parse out compatability.
    #
    # This is complicated by Starlark as with Python not treating lists as
    # values, so we have to go to strings of JSON in order to get value
    # semantics which is frustrating.

    # The strategy here is to roll through the wheels,
    configuration_set = {}
    select_arms = {}

    for whl in prebuilds.keys():
        parsed = parse_whl_name(whl)

        # FIXME: Move these splits to Ignas' code? Why not?
        for python_tag in parsed.python_tags:
            for platform_tag in parsed.platform_tags:
                for abi_tag in parsed.abi_tags:

                    print(whl, "{}-{}-{}".format(python_tag, platform_tag, abi_tag))

    content = [
        "# FIXME",
        "load(\"@aspect_rules_py//pip/private/whl_install:rule.bzl\", \"whl_install\")",
    ]

    # Craft the select statement for the source wheel
    content.append(
"""
alias(
   name = '_whl',
   actual = select({}, no_match_error = "FIXME"),
)
""".format(repr(select_arms))
)

    aliases = [
        "".format(name, spec["name"])
        for name, spec in prebuilds.items()
    ]

    repository_ctx.file("BUILD.bazel", content = "\n".join(aliases))


whl_install = repository_rule(
    implementation = _whl_install_impl,
    attrs = {
        "prebuilds": attr.string(),
        "sbuild": attr.label(),
    },
)
