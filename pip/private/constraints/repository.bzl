def format_list(items):
    return "[\n" + "".join(["    {},\n".format(repr(it)) for it in items]) + "]"

def _constraints_hub_impl(repository_ctx):
    ################################################################################
    content = [
        "load(\"@bazel_skylib//lib:selects.bzl\", \"selects\")",
    ]

    for name, conditions in repository_ctx.attr.configurations.items():
        content.append(
            """
selects.config_setting_group(
    name = "{}",
    match_all = {},
)
""".format(name, format_list(conditions)),
        )

    repository_ctx.file("BUILD.bazel", content = "\n".join(content))

configurations_hub = repository_rule(
    implementation = _constraints_hub_impl,
    attrs = {
        "configurations": attr.string_list_dict(),
    },
)
