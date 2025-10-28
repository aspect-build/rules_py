"""

Generate a cluster of config_settings which bridge from well-known static config
features (interpreter feature flags, interpreter version, platform, etc.) to the
dynamic(ish) set of Python platform "triples" defined by the lockfile.

This bridging allows wheel selection to occur in Python-native terms according
to just the Python platform triple which is defined elsewhere/centrally (here),
and makes debugging easier as well as the generated selections more meaningful.

"""

def _format_list(items):
    return "[\n" + "".join(["    {},\n".format(repr(it)) for it in items]) + "]"

def _constraints_hub_impl(repository_ctx):
    ################################################################################
    content = [
        "load(\"@bazel_skylib//lib:selects.bzl\", \"selects\")",
    ]

    for name, conditions in repository_ctx.attr.configurations.items():
        # FIXME: Set visibility narrowly? Would have to be to all the hubs and
        # all the wheels, feels like a lot of work.
        content.append(
            """
selects.config_setting_group(
    name = "{}",
    match_all = {},
    visibility = ["//visibility:public"],
)
""".format(name, _format_list(conditions)),
        )

    repository_ctx.file("BUILD.bazel", content = "\n".join(content))

configurations_hub = repository_rule(
    implementation = _constraints_hub_impl,
    attrs = {
        "configurations": attr.string_list_dict(),
    },
)
