"""

Wheel installation repos are actually a bit tricky because this is where we go
from wheel files to a filegroup/py_library. That means we have to perform
platform wheel selection here as well as invoking the installation action to
produce a filegroup/TreeArtifact.

"""

load(":parse_whl_name.bzl", "parse_whl_name")


def _whl_install_impl(repository_ctx):
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
    content = [
        "load(\"@aspect_rules_py//pip/private/whl_install:rule.bzl\", \"whl_install\")",
        "load(\"@bazel_skylib//lib:selects.bzl\", \"selects\")",
    ]

    for whl, target in prebuilds.items():
        parsed = parse_whl_name(whl)

        # FIXME: Move these splits to Ignas' code? Why not?
        for python_tag in parsed.python_tags:
            for platform_tag in parsed.platform_tags:
                for abi_tag in parsed.abi_tags:
                    select_arms["@aspect_rules_py_pip_configurations//:{}-{}-{}".format(python_tag, platform_tag, abi_tag)] = "@" + target

    # FIXME: Add a way to force the use of a source build in this select
    content.append(
"""
alias(
   name = 'whl',
   actual = select({}),
)
""".format(
    repr(select_arms | {"//conditions:default": str(repository_ctx.attr.sbuild)}),
)
)
    content.append(
"""
# FIXME: What more do we need here?
whl_install(
   name = "install",
   srcs = [":whl"],
   visibility = ["//visibility:public"],
)
""")
    repository_ctx.file("BUILD.bazel", content = "\n".join(content))


whl_install = repository_rule(
    implementation = _whl_install_impl,
    attrs = {
        "prebuilds": attr.string(),
        "sbuild": attr.label(),
    },
)
