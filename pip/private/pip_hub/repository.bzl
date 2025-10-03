def _pip_hub_impl(repository_ctx):
    repository_ctx.file("BUILD.bazel", "")

    ################################################################################
    content = [
        "load(\"@bazel_skylib//lib:selects.bzl\", \"selects\")",
    ]

    for name, conditions in repository_ctx.attr.configurations.items():
        content.append(
            """\
selects.config_setting_group(
    name = "{}",
    match_all = {},
)
""".format(name, repr(conditions)),
        )

    repository_ctx.file("configuration/BUILD.bazel", content = "\n".join(content))

    ################################################################################
    content = [
        """\
# FIXME

alias(
    name = "venv",
    actual = "@aspect_rules_py//pip/private/constraints/venv:venv"
)
""",
    ]

    # Lay down the venv config settings
    for name in repository_ctx.attr.venvs:
        content.append(
            """
config_setting(
    name = "{0}",
    flag_values = {{
        "@aspect_rules_py//pip/private/constraints/venv:venv": "{0}",
    }},
    visibility = ["//:__subpackages__"],
)
""".format(name),
        )
    repository_ctx.file("venv/BUILD.bazel", content = "\n".join(content))

    ################################################################################
    content = [
        "# FIXME ",
    ]

    content.append(
        """
_VENVS = {}

def _compatible_with(venvs, extra_constraints = []):
  return select({{
    Label("//venv:" + it): extra_constraints
    for it in venvs
  }} | {{
    "//conditions:default": ["@platforms//:incompatible"],
  }})

pip = struct(
  compatible_with = _compatible_with,
)
""".format(repr(repository_ctx.attr.venvs)),
    )

    repository_ctx.file("defs.bzl", content = "\n".join(content))

    ################################################################################
    content = [
        """
load("//:defs.bzl", "pip")
""",
    ]

    # Lay down the hub aliases
    for name, spec in repository_ctx.attr.packages.items():
        select_spec = {
            "//venv:{}".format(it): "@venv__{}__{}//:{}".format(repository_ctx.attr.hub_name, it, name)
            for it in spec
        }

        content.append(
            """
alias(
    name = "{name}",
    actual = select(
      {select},
      no_match_error = "{error}",
    ),
    target_compatible_with = pip.compatible_with({compat}),
    visibility = ["//visibility:public"],
)
""".format(
                name = name,
                select = repr(select_spec),
                compat = repr(spec),
                error = "Available only in venvs " + ", ".join([it.split(":")[1][1:] for it in select_spec.keys()]),
            ),
        )

    repository_ctx.file("package/BUILD.bazel", content = "\n".join(content))

pip_hub = repository_rule(
    implementation = _pip_hub_impl,
    attrs = {
        "hub_name": attr.string(),
        "venvs": attr.string_list(),
        "packages": attr.string_list_dict(),
        "configurations": attr.string_list_dict(),
    },
)
